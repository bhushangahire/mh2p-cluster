package de.audi.app.terminalmode.smartphone.androidauto2.nav;

import de.audi.app.terminalmode.IContext;
import org.dsi.ifc.map.DSIMapViewerControl;
import org.osgi.framework.BundleContext;
import org.osgi.framework.ServiceReference;
import org.osgi.util.tracker.ServiceTracker;
import org.osgi.util.tracker.ServiceTrackerCustomizer;

import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * Hides the native Audi map in the virtual cockpit while the Android Auto
 * cluster video renders, shows it again afterwards, and decides once per HMI
 * start whether AA needs one reconnect.
 *
 * Why (Audi Q7, MH2p P2711): the native cockpit map viewer (DSIMapViewerControl
 * instance 3) draws into displayable 33 on top of the AA video, so it has to be
 * suspended and hidden while AA renders. On a cold boot AA connects before the
 * navigation is up and the video still does not show; one AA reconnect after
 * the navigation is ready (the airplane-mode trick) fixes it. The show path
 * must not call IMapClusterService.notifyViewSizeChanged(true): the HMI then
 * re-measures the cockpit into the small map layout and the AA video stays
 * boxed between the gauges for the rest of the drive (on-car logs, 2026-11-03).
 *
 * How: a daemon thread polls AndroidAutoClusterIntegration.clusterState
 * (2 = RENDERING) once a second. IMapClusterService is found by an OSGi
 * ServiceTracker on the class name plus service-manager retries,
 * DSIMapViewerControl instance 3 by service-manager retries. On RENDERING:
 * suspend the viewer, viewSetVisible(false), switchKombiMapToHiddenContext(),
 * re-applied every REAPPLY_MS. When the video stops, SHOW_DELAY_MS later: wake
 * the viewer, viewSetVisible(true), hidden then shown context. Once both
 * services are found and SETTLE_MS has passed, write /tmp/kill_gal_now if the
 * video was rendering before that point, else /tmp/kill_gal_skip;
 * Persist/kill_gal_watcher.sh acts on the flag (slays gal.real, the phone
 * reconnects). Every call is reflective inside a catch-all. Java 1.4 source.
 */
public class KombiMapGuard implements Runnable, ServiceTrackerCustomizer {

    public static final String BUILD = "kombi-guard q7-trigger 2026-11-03b";

    private static final String MAP_CLUSTER_CLASS = "de.audi.tghu.navi.app.cluster.IMapClusterService";
    private static final String KILL_FLAG = "/tmp/kill_gal_now";
    private static final String SKIP_FLAG = "/tmp/kill_gal_skip";
    private static final int CL_RENDERING = 2;
    private static final int KOMBI_INSTANCE = 3;
    private static final long POLL_MS = 1000L;
    private static final long LOOKUP_RETRY_MS = 5000L;
    // Time after both services appear for the cockpit map to finish loading.
    private static final long SETTLE_MS = 10000L;
    private static final long REAPPLY_MS = 10000L;
    private static final long SHOW_DELAY_MS = 1200L;

    private final IContext context;
    private final AndroidAutoClusterIntegration integration;
    private Field stateField;
    private BundleContext bundleContext;
    private ServiceTracker tracker;
    private DSIMapViewerControl kombiViewer;
    private Object mapClusterService;
    private long lastLookup = 0L;
    private boolean codingLogged = false;
    private boolean hidden = false;
    private boolean suspended = false;
    private long lastApply = 0L;
    private long showAt = 0L;
    private boolean renderedEarly = false;
    private long readyAt = 0L;
    private boolean decided = false;

    private KombiMapGuard(IContext context, AndroidAutoClusterIntegration integration) {
        this.context = context;
        this.integration = integration;
    }

    /** Starts the guard thread. Never throws. */
    public static void start(IContext context, AndroidAutoClusterIntegration integration) {
        try {
            KombiMapGuard guard = new KombiMapGuard(context, integration);
            Thread t = new Thread(guard, "KombiMapGuard");
            t.setDaemon(true);
            t.setPriority(Thread.MIN_PRIORITY);
            t.start();
        } catch (Throwable t) {
            safeLog(integration, "KOMBI_MAP: guard not started: " + t);
        }
    }

    public void run() {
        log(BUILD + " started");
        try {
            stateField = AndroidAutoClusterIntegration.class.getDeclaredField("clusterState");
            stateField.setAccessible(true);
        } catch (Throwable t) {
            log("clusterState field not found, guard stopped: " + t);
            return;
        }
        openTracker();
        while (true) {
            try {
                tick();
            } catch (Throwable t) {
                log("tick error: " + t);
            }
            try {
                Thread.sleep(POLL_MS);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    private void tick() throws Exception {
        long now = System.currentTimeMillis();
        if ((kombiViewer == null || mapClusterService == null) && now - lastLookup >= LOOKUP_RETRY_MS) {
            lastLookup = now;
            lookup();
        }
        if (!codingLogged) {
            logNavMapTransmissionMode();
        }
        boolean rendering = stateField.getInt(integration) == CL_RENDERING;
        if (rendering && (!hidden || now - lastApply >= REAPPLY_MS)) {
            if (!hidden) {
                showAt = 0L;
                log("AA video rendering, hiding native cockpit map"
                        + " (viewer=" + (kombiViewer != null) + " mapCluster=" + (mapClusterService != null) + ")");
            }
            hideNative(!hidden || !suspended);
            hidden = true;
            lastApply = now;
        } else if (!rendering && hidden) {
            log("AA video stopped, showing native cockpit map in " + SHOW_DELAY_MS + " ms");
            hidden = false;
            showAt = now + SHOW_DELAY_MS;
        }
        if (showAt != 0L && now >= showAt) {
            showAt = 0L;
            showNative();
        }
        if (readyAt == 0L && kombiViewer != null && mapClusterService != null) {
            readyAt = now;
            log("navigation services ready, deciding in " + (SETTLE_MS / 1000) + " s");
        }
        if (rendering && (readyAt == 0L || now - readyAt < SETTLE_MS)) {
            renderedEarly = true;
        }
        if (!decided && readyAt != 0L && now - readyAt >= SETTLE_MS) {
            decided = true;
            if (renderedEarly) {
                log("AA started before the navigation was ready, asking for one reconnect");
                touch(KILL_FLAG);
            } else {
                log("navigation was ready before AA, no reconnect needed");
                touch(SKIP_FLAG);
            }
        }
    }

    /** Viewer suspended once per session; visibility and context re-applied. */
    private void hideNative(boolean suspend) {
        if (kombiViewer != null) {
            if (suspend) {
                try {
                    kombiViewer.suspendMapViewer();
                    suspended = true;
                    log("native kombi map viewer suspended");
                } catch (Throwable t) {
                    log("suspendMapViewer failed: " + t);
                }
            }
            try {
                kombiViewer.viewSetVisible(false);
            } catch (Throwable t) {
                log("viewSetVisible(false) failed: " + t);
            }
        }
        callMapCluster("switchKombiMapToHiddenContext");
    }

    /** No notifyViewSizeChanged here: it shrinks the cockpit map layout. */
    private void showNative() {
        if (kombiViewer != null) {
            try {
                if (suspended) {
                    kombiViewer.wakeupMapViewer();
                }
                kombiViewer.viewSetVisible(true);
                kombiViewer.viewFreeze(false);
                log("native kombi map viewer woken");
            } catch (Throwable t) {
                log("waking native viewer failed: " + t);
            }
        }
        suspended = false;
        callMapCluster("switchKombiMapToHiddenContext");
        callMapCluster("switchKombiMapToAShownContext");
    }

    private void callMapCluster(String method) {
        Object s = mapClusterService;
        if (s == null) {
            return;
        }
        try {
            Method m = s.getClass().getMethod(method, new Class[0]);
            m.invoke(s, new Object[0]);
        } catch (Throwable t) {
            log(method + " failed: " + t);
        }
    }

    private void touch(String path) {
        try {
            new FileOutputStream(path).close();
            log("wrote " + path);
        } catch (Throwable t) {
            log("could not write " + path + ": " + t);
        }
    }

    // ---- finding the services ------------------------------------------------

    private void openTracker() {
        try {
            bundleContext = context.getServiceManager().getBundleContext();
        } catch (Throwable t) {
            log("bundle context unavailable: " + t);
            return;
        }
        if (bundleContext == null) {
            log("bundle context is null; tracker not started");
            return;
        }
        try {
            tracker = new ServiceTracker(bundleContext, MAP_CLUSTER_CLASS, this);
            tracker.open();
            log("tracking " + MAP_CLUSTER_CLASS + " by name ("
                    + (mapClusterService != null ? "already registered" : "not registered yet, waiting") + ")");
        } catch (Throwable t) {
            log("ServiceTracker failed: " + t);
        }
    }

    public Object addingService(ServiceReference reference) {
        Object s = null;
        try {
            s = bundleContext.getService(reference);
        } catch (Throwable t) {
            log("getService failed: " + t);
        }
        if (s != null) {
            mapClusterService = s;
            log("IMapClusterService registered (tracker, class=" + s.getClass().getName() + ")");
        }
        return s;
    }

    public void modifiedService(ServiceReference reference, Object s) {
    }

    public void removedService(ServiceReference reference, Object s) {
        if (mapClusterService == s) {
            mapClusterService = null;
        }
        try {
            bundleContext.ungetService(reference);
        } catch (Throwable t) {
            // nothing to do
        }
        log("IMapClusterService unregistered");
    }

    private void lookup() {
        if (kombiViewer == null) {
            try {
                ServiceReference[] refs = context.getServiceManager().getServiceReferences(DSIMapViewerControl.class);
                for (int i = 0; refs != null && i < refs.length; i++) {
                    Object inst = refs[i].getProperty("DEVICE_INSTANCE");
                    if (inst instanceof Integer && ((Integer) inst).intValue() == KOMBI_INSTANCE) {
                        kombiViewer = (DSIMapViewerControl) context.getServiceManager().getService(refs[i]);
                        if (kombiViewer != null) {
                            log("DSIMapViewerControl(KOMBI=3) found");
                        }
                        break;
                    }
                }
            } catch (Throwable t) {
                log("DSIMapViewerControl lookup failed: " + t);
            }
        }
        if (mapClusterService == null) {
            try {
                Class c = Class.forName(MAP_CLUSTER_CLASS);
                ServiceReference[] refs = context.getServiceManager().getServiceReferences(c);
                if (refs != null && refs.length > 0) {
                    mapClusterService = context.getServiceManager().getService(refs[0]);
                    if (mapClusterService != null) {
                        log("IMapClusterService found (service manager)");
                    }
                }
            } catch (Throwable t) {
                log("IMapClusterService lookup failed: " + t);
            }
        }
    }

    /** One log line with the car's coding: 3 = virtual cockpit (arrows go by video, not BAP). */
    private void logNavMapTransmissionMode() {
        try {
            Class c = Class.forName("de.audi.mib.system.ISysServices");
            ServiceReference[] refs = context.getServiceManager().getServiceReferences(c);
            if (refs == null || refs.length == 0) {
                return;
            }
            Object o = context.getServiceManager().getService(refs[0]);
            String[] chain = {"config", "rawCoding", "displayConfig", "getNavMapTransmissionMode"};
            for (int i = 0; o != null && i < chain.length; i++) {
                Method m = o.getClass().getMethod(chain[i], new Class[0]);
                m.setAccessible(true); // implementation classes may be package-private
                o = m.invoke(o, new Object[0]);
            }
            log("coding navMapTransmissionMode=" + o + " (3 = virtual cockpit)");
        } catch (Throwable t) {
            log("navMapTransmissionMode not readable: " + t);
        }
        codingLogged = true;
    }

    private void log(String msg) {
        safeLog(integration, "KOMBI_MAP: " + msg);
    }

    private static void safeLog(AndroidAutoClusterIntegration integration, String msg) {
        try {
            integration.logCluster(msg);
        } catch (Throwable t) {
            // logging must never take Android Auto down
        }
    }
}

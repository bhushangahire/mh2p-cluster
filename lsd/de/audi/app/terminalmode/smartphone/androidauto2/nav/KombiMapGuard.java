package de.audi.app.terminalmode.smartphone.androidauto2.nav;

import de.audi.app.terminalmode.IContext;
import org.dsi.ifc.map.DSIMapViewerControl;
import org.osgi.framework.BundleContext;
import org.osgi.framework.ServiceReference;
import org.osgi.util.tracker.ServiceTracker;
import org.osgi.util.tracker.ServiceTrackerCustomizer;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * Hides the native Audi navigation map in the virtual cockpit while the
 * Android Auto cluster video is rendering, and shows it again afterwards.
 *
 * Why: on an Audi Q7 (MH2p P2711, AU_G35) the cockpit map context 25 holds
 * displayables {41, 33}. The cluster daemon posts the AA video into 33, but
 * the native navigation's cockpit map viewer (DSIMapViewerControl instance 3)
 * keeps drawing into 33 as well and stays on top. On an e-tron (P2873) the
 * cockpit went black after Android Auto ended because nothing asked the Audi
 * map back. The shipped AndroidAutoClusterIntegration has
 * suspendNativeNavCluster() but never calls it, and its one-time service
 * lookups run too early at boot.
 *
 * How: a daemon thread polls AndroidAutoClusterIntegration.clusterState
 * (2 = RENDERING) once a second. The two navigation services are found two
 * ways: IMapClusterService through an OSGi ServiceTracker on the class NAME
 * (what the stock navigation's MapClusterServiceProxy does, so it is found
 * whenever the navigation bundle registers it) and both through the terminal
 * mode service manager, retried until found. On RENDERING it suspends the
 * kombi map viewer, calls viewSetVisible(false) and
 * IMapClusterService.switchKombiMapToHiddenContext() (the mod's own
 * suspendNativeNavCluster() sequence); when the video stops it runs the mod's
 * wakeNativeNavCluster() sequence 1.2 s later, once the mod's video window
 * is gone (the stock "shown" path, startActivity + enterMapScreen, is a
 * no-op while the HMI believes the map is already shown, hence hide first),
 * followed by notifyViewSizeChanged(true). It never switches display
 * contexts (context 25 is what keeps displayable 33 in the cockpit). Every
 * call goes through reflection inside a catch-all: a failure is logged and
 * Android Auto keeps running. At the first RENDERING it logs the registered
 * OSGi services whose names look map/cluster related, so a failed lookup on
 * a new car leaves evidence (KOMBI_MAP: service: lines in cluster.log).
 *
 * Based on KombiMapGuard by Bhushan Ahire (PR #11, Q7 P2711) with the
 * ServiceTracker, delayed show and service inventory from KombiMapHandback
 * (e-tron P2873). Java 1.4 source level (the HMI JVM loads class-file
 * version 48).
 */
public class KombiMapGuard implements Runnable, ServiceTrackerCustomizer {

    public static final String BUILD = "kombi-guard 2026-10-18a";

    private static final String MAP_CLUSTER_CLASS = "de.audi.tghu.navi.app.cluster.IMapClusterService";
    private static final int CL_RENDERING = 2;
    private static final int KOMBI_INSTANCE = 3;
    private static final long POLL_MS = 1000L;
    private static final long LOOKUP_RETRY_MS = 5000L;
    // Fixed re-apply interval; make it configurable if the native
    // map ever flickers back between re-applies.
    private static final long REAPPLY_MS = 10000L;
    private static final long SHOW_DELAY_MS = 1200L;

    private final IContext context;
    private final AndroidAutoClusterIntegration integration;
    private Field stateField;
    private BundleContext bundleContext;
    private ServiceTracker tracker;
    private DSIMapViewerControl kombiViewer;
    private Object mapClusterService;
    private boolean hidden = false;
    private boolean suspended = false;
    private long lastLookup = 0L;
    private long lastApply = 0L;
    private long showAt = 0L;
    private boolean codingLogged = false;
    private boolean servicesDumped = false;

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
                if (!servicesDumped) {
                    servicesDumped = true;
                    dumpServices();
                }
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
    }

    /**
     * Same calls, same order as the mod's own (never called)
     * suspendNativeNavCluster(). The viewer is suspended once per session;
     * visibility and context are re-applied every REAPPLY_MS.
     */
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

    /**
     * Same calls, same order as the mod's own wakeNativeNavCluster(), then
     * notifyViewSizeChanged(true) so the HMI re-measures the cockpit view.
     */
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
        if (mapClusterService == null) {
            log("IMapClusterService NOT available, cannot ask the Audi map back");
            dumpServices();
            return;
        }
        callMapCluster("switchKombiMapToHiddenContext");
        callMapCluster("switchKombiMapToAShownContext");
        callMapClusterBoolean("notifyViewSizeChanged", true);
    }

    private void callMapCluster(String method) {
        Object s = mapClusterService;
        if (s == null) {
            log(method + " skipped - IMapClusterService not available");
            return;
        }
        try {
            Method m = s.getClass().getMethod(method, new Class[0]);
            m.invoke(s, new Object[0]);
            log("IMapClusterService." + method + "() invoked");
        } catch (Throwable t) {
            log(method + " failed: " + t);
        }
    }

    private void callMapClusterBoolean(String method, boolean arg) {
        Object s = mapClusterService;
        if (s == null) {
            return;
        }
        try {
            Method m = s.getClass().getMethod(method, new Class[] { Boolean.TYPE });
            m.invoke(s, new Object[] { arg ? Boolean.TRUE : Boolean.FALSE });
            log("IMapClusterService." + method + "(" + arg + ") invoked");
        } catch (Throwable t) {
            log(method + " failed: " + t);
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

    /**
     * Lists the registered OSGi services whose class names look cluster/map
     * related, with DEVICE_INSTANCE / DEVICE_NAME where set, so a failed
     * lookup leaves evidence of what this HMI offers.
     */
    private void dumpServices() {
        if (bundleContext == null) {
            return;
        }
        try {
            ServiceReference[] refs = bundleContext.getServiceReferences(null, null);
            int total = (refs == null) ? 0 : refs.length;
            int listed = 0;
            StringBuffer sb = new StringBuffer();
            for (int i = 0; refs != null && i < refs.length && listed < 120; i++) {
                Object oc = refs[i].getProperty("objectClass");
                if (!(oc instanceof String[])) {
                    continue;
                }
                String[] names = (String[]) oc;
                for (int n = 0; n < names.length; n++) {
                    String name = names[n];
                    if (name.indexOf("Map") >= 0 || name.indexOf("Kombi") >= 0 || name.indexOf("Cluster") >= 0
                            || name.indexOf("Combi") >= 0 || name.indexOf("Zoom") >= 0 || name.indexOf("navi") >= 0) {
                        sb.setLength(0);
                        sb.append("service: ").append(name);
                        Object inst = refs[i].getProperty("DEVICE_INSTANCE");
                        Object dev = refs[i].getProperty("DEVICE_NAME");
                        if (inst != null) {
                            sb.append(" DEVICE_INSTANCE=").append(inst);
                        }
                        if (dev != null) {
                            sb.append(" DEVICE_NAME=").append(dev);
                        }
                        log(sb.toString());
                        listed++;
                        break;
                    }
                }
            }
            log("service dump done: " + listed + " of " + total + " registered services listed");
        } catch (Throwable t) {
            log("service dump failed: " + t);
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

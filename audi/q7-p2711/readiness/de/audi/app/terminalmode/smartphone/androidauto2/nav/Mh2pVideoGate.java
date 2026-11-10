/* Licensed under CC BY-NC-SA 4.0, matching this MH2p repository.
 * https://creativecommons.org/licenses/by-nc-sa/4.0/
 */
package de.audi.app.terminalmode.smartphone.androidauto2.nav;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.WeakHashMap;

/** MH2p P2711 cockpit-window gate. Does not gate AA transport or BAP data.
 * Uses only read-only reflection against the supplied stock P2711 classes.
 * A missing/incompatible API keeps secondary video waiting, never times out.
 * The boot latch lives in this JVM, not /tmp (which survives HMI restarts).
 */
public final class Mh2pVideoGate {
    private static final WeakHashMap gates = new WeakHashMap();
    private static volatile boolean ready;
    private String prepare;
    private boolean warmPrepared;
    private String start;

    private static synchronized Mh2pVideoGate gate(Object integration) {
        Mh2pVideoGate g = (Mh2pVideoGate) gates.get(integration);
        if (g == null) {
            g = new Mh2pVideoGate();
            gates.put(integration, g);
        }
        return g;
    }

    public static boolean isReady() { return ready; }

    /** Called by the instrumented release sendMirrorCommand, before any FIFO I/O.
     * Before readiness, h264 prepare warms an invisible decoder; resume is held.
     * Stop releases that child (the v1.5 daemon skips its stop splash).
     * Commands are coalesced so a phone unplug cannot replay an old resume.
     */
    public static void send(Object integration, String command) {
        Mh2pVideoGate g = gate(integration);
        synchronized (g) {
            if (ready) {
                g.flush(integration);
                raw(integration, command);
                return;
            }
            if (command.startsWith("prepare ") || "prepare".equals(command)) {
                g.start = null;
                if (command.indexOf("capture=h264") >= 0) {
                    // Verified v1.5 PREPARE decodes continuously but keeps its
                    // window invisible and skips screen_post_window. This
                    // consumes SPS/PPS/IDR immediately instead of losing them
                    // when the 2 MB ring wraps during a long OEM-map startup.
                    g.prepare = null;
                    raw(integration, command);
                    g.warmPrepared = true;
                } else {
                    g.prepare = command;
                }
            } else if (command.startsWith("start ") || "start".equals(command)) {
                g.prepare = null;
                g.start = command;
            } else if ("resume".equals(command)) {
                g.start = command;
            } else if ("pause".equals(command)) {
                g.start = null;
            } else if ("stop".equals(command)) {
                g.prepare = null;
                g.start = null;
                if (g.warmPrepared) raw(integration, command);
                g.warmPrepared = false;
            }
            // Unknown commands are deliberately not sent before readiness.
        }
    }

    /** Guard thread only. Resolves the exact wrapper and fields found in P2711.
     * No stock navigation method that changes state is called here. mapDrawn is
     * volatile in stock; read it before the initialization flag. The service
     * wrapper itself holds a weak reference; get() can legitimately return null.
     */
    public static void poll(Object integration, Object service) throws Exception {
        if (!ready && stockMapReady(service)) {
            ready = true;
            log(integration, "MH2P_VIDEO_GATE READY initialized=1 first_drawn=1");
        }
        if (ready) {
            Mh2pVideoGate g = gate(integration);
            synchronized (g) { g.flush(integration); }
        }
    }

    static boolean stockMapReady(Object service) throws Exception {
        if (service == null) return false;
        Class wrapper = Class.forName("de.audi.tghu.navi.app.map.osgi.wrapper.IMapClusterServiceWrapper");
        if (wrapper.isInstance(service)) {
            Class base = Class.forName("de.audi.tghu.navi.app.util.AbstractNaviServiceWrapper");
            Method get = base.getDeclaredMethod("get", new Class[0]);
            get.setAccessible(true);
            service = get.invoke(service, new Object[0]);
        }
        if (service == null) return false;
        Class impl = Class.forName("de.audi.tghu.navi.app.cluster.MapClusterService");
        if (!impl.isInstance(service)) return false;
        Field mapField = impl.getDeclaredField("kombiMap");
        mapField.setAccessible(true);
        Object map = mapField.get(service);
        if (map == null) return false;
        Class abstractMap = Class.forName("de.audi.tghu.navi.app.map.AbstractMap");
        Field drawn = abstractMap.getDeclaredField("mapDrawn");
        if (!Modifier.isVolatile(drawn.getModifiers())) return false;
        drawn.setAccessible(true);
        // isInitialized() was verified to be a pure mMapInitialized field read.
        return drawn.getBoolean(map) && Boolean.TRUE.equals(
            abstractMap.getMethod("isInitialized", new Class[0]).invoke(map, new Object[0]));
    }

    private void flush(Object integration) {
        // Serialize with every new command, including disconnect/pause.
        String p = prepare, s = start;
        prepare = null;
        start = null;
        if (p != null) raw(integration, p);
        if (s != null) raw(integration, s);
    }

    private static void raw(Object integration, String command) {
        try {
            Method m = integration.getClass().getDeclaredMethod("sendMirrorCommandUngated",
                new Class[] { Class.forName("java.lang.String") });
            m.setAccessible(true);
            m.invoke(integration, new Object[] { command });
        } catch (Throwable failure) {
            log(integration, "MH2P_VIDEO_GATE command failed: " + failure);
        }
    }

    private static void log(Object integration, String message) {
        try {
            Method m = integration.getClass().getMethod("logCluster",
                new Class[] { Class.forName("java.lang.String") });
            m.invoke(integration, new Object[] { message });
        } catch (Throwable ignored) { }
    }
}

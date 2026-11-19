/* Licensed under CC BY-NC-SA 4.0, matching this repository. */
package de.audi.app.terminalmode.smartphone.androidauto2.nav;

import java.lang.reflect.Field;

/**
 * Shows the AA cockpit video through displayable 62 instead of 33.
 *
 * Why: the player used to register its window as displayable 33, which made
 * the display manager drop Audi's own cockpit map source and never restore
 * it, so the cockpit stayed black after AA stopped. With the player on 62,
 * Audi's map keeps source 33 and this class only switches the cockpit
 * composition: while AA video renders and the HMI wants 33 in the cockpit,
 * show the HMI's own list with 33 replaced by 62 ("dmdt sd 4 ..."); otherwise
 * hand the cockpit back to the HMI's buffered composition ("dmdt sb 4").
 *
 * The HMI's wanted cockpit list is read in memory from the stock
 * DisplayManager (terminal 1), so a cockpit view change is followed without
 * running any query tool. dmdt runs only when the wanted composition changes,
 * at most one child at a time, output discarded, never waited on: each tick
 * checks exitValue() and a child older than CHILD_MAX_MS is destroyed.
 */
final class Mh2pCockpitRoute {
    private static final String DMDT = "/mnt/app/eso/bin/apps/dmdt";
    private static final int COCKPIT_DISPLAY = 4;  // dmdt display of HMI terminal 1
    private static final int COCKPIT_TERMINAL = 1;
    private static final int NATIVE_MAP = 33;
    private static final int AA_MAP = 62;
    private static final long CHILD_MAX_MS = 10000L;

    private final KombiLog log;
    private String applied;  // composition we asked for; null = HMI owns the cockpit
    private Process child;
    private String childCmd;
    private long childAt;
    private String lastError;

    interface KombiLog { void log(String msg); }

    Mh2pCockpitRoute(KombiLog log) { this.log = log; }

    /** Called once a second from the guard thread. Never throws. */
    void tick(boolean rendering, long now) {
        try {
            if (!reap(now)) return;  // previous dmdt still running
            String want = null;
            if (rendering) {
                int[] hmi = hmiCockpitLayers();
                if (hmi != null && contains(hmi, NATIVE_MAP)) want = "sd " + COCKPIT_DISPLAY + replaced(hmi);
            }
            if (want == null) {
                if (applied != null) run("sb " + COCKPIT_DISPLAY, now, null);
            } else if (!want.equals(applied)) {
                run(want, now, want);
            }
        } catch (Throwable t) {
            String e = t.toString();
            if (!e.equals(lastError)) { lastError = e; log.log("ROUTE error: " + e); }
        }
    }

    /** True when no child is running (after collecting a finished one). */
    private boolean reap(long now) {
        if (child == null) return true;
        try {
            int rc = child.exitValue();
            log.log("ROUTE dmdt " + childCmd + " exit=" + rc);
            child = null;
            return true;
        } catch (IllegalThreadStateException running) {
            if (now - childAt < CHILD_MAX_MS) return false;
            child.destroy();
            log.log("ROUTE dmdt " + childCmd + " timed out, destroyed");
            child = null;
            return true;
        }
    }

    private void run(String args, long now, String nowApplied) throws Exception {
        String cmd = DMDT + " " + args + " >/dev/null 2>&1 </dev/null";
        Process p = Runtime.getRuntime().exec(new String[] { "/bin/ksh", "-c", cmd });
        // No reader threads: output goes to /dev/null, so close our ends now.
        try { p.getInputStream().close(); } catch (Throwable ignored) { }
        try { p.getErrorStream().close(); } catch (Throwable ignored) { }
        try { p.getOutputStream().close(); } catch (Throwable ignored) { }
        child = p;
        childCmd = args;
        childAt = now;
        applied = nowApplied;
        log.log("ROUTE requested dmdt " + args);
    }

    /** The HMI's wanted cockpit displayables, e.g. {41, 33}; null if unknown. */
    static int[] hmiCockpitLayers() throws Exception {
        Class dm = Class.forName("de.eso.hmiservice.display.DisplayManager");
        int[] list = layers(dm, "requestedContexts");
        return list != null ? list : layers(dm, "confirmedActiveContext");
    }

    private static int[] layers(Class dm, String name) throws Exception {
        Field f = dm.getDeclaredField(name);
        f.setAccessible(true);
        Object[] contexts = (Object[]) f.get(null);
        if (contexts == null || contexts.length <= COCKPIT_TERMINAL) return null;
        Object ctx = contexts[COCKPIT_TERMINAL];
        if (ctx == null) return null;
        Field l = ctx.getClass().getField("displayableList");
        return (int[]) l.get(ctx);
    }

    static boolean contains(int[] a, int v) {
        for (int i = 0; i < a.length; i++) if (a[i] == v) return true;
        return false;
    }

    static String replaced(int[] a) {
        StringBuffer b = new StringBuffer();
        for (int i = 0; i < a.length; i++) b.append(' ').append(a[i] == NATIVE_MAP ? AA_MAP : a[i]);
        return b.toString();
    }
}

import de.audi.app.terminalmode.smartphone.androidauto2.nav.Mh2pVideoGate;
import de.audi.tghu.navi.app.map.AbstractMap;
import de.audi.tghu.navi.app.cluster.MapClusterService;
import de.audi.tghu.navi.app.map.osgi.wrapper.IMapClusterServiceWrapper;

public class GateTest {
    public static class Integration {
        StringBuffer calls = new StringBuffer();
        private void sendMirrorCommandUngated(String c) { calls.append(c).append(";"); }
        public void logCluster(String c) { }
    }
    static void check(boolean b, String name) {
        if (!b) throw new AssertionError(name);
        System.out.println("PASS " + name);
    }
    public static void main(String[] args) throws Exception {
        Integration active = new Integration(), unplugged = new Integration(), paused = new Integration();
        AbstractMap map = new AbstractMap();
        Object wrapper = new IMapClusterServiceWrapper(new MapClusterService(map));
        Mh2pVideoGate.send(active, "prepare capture=h264 mode=fill zoomX=1.1");
        Mh2pVideoGate.send(active, "resume");
        Mh2pVideoGate.poll(active, null);
        check(active.calls.toString().equals("prepare capture=h264 mode=fill zoomX=1.1;") && !Mh2pVideoGate.isReady(), "no service: decoder warms without resume");
        Mh2pVideoGate.poll(active, new IMapClusterServiceWrapper(null));
        check(!Mh2pVideoGate.isReady(), "expired wrapper does not release");
        Mh2pVideoGate.poll(active, new MapClusterService(null));
        check(!Mh2pVideoGate.isReady(), "registered service without map does not release");
        map.set(false, true); Mh2pVideoGate.poll(active, wrapper);
        check(!Mh2pVideoGate.isReady(), "first draw without initialization does not release");
        map.set(true, false); Mh2pVideoGate.poll(active, wrapper);
        check(!Mh2pVideoGate.isReady(), "initialization without first draw does not release");
        Mh2pVideoGate.send(unplugged, "prepare capture=h264");
        Mh2pVideoGate.send(unplugged, "resume");
        Mh2pVideoGate.send(unplugged, "stop");
        Mh2pVideoGate.send(paused, "prepare capture=h264");
        Mh2pVideoGate.send(paused, "resume");
        Mh2pVideoGate.send(paused, "pause");
        Integration reconnect = new Integration(), mirror = new Integration();
        Mh2pVideoGate.send(reconnect, "prepare capture=h264 mode=letter");
        Mh2pVideoGate.send(reconnect, "resume");
        Mh2pVideoGate.send(reconnect, "stop");
        Mh2pVideoGate.send(reconnect, "prepare capture=h264 mode=fill");
        Mh2pVideoGate.send(reconnect, "resume");
        Mh2pVideoGate.send(mirror, "start capture=mirror mode=fill");
        check(mirror.calls.length() == 0, "non-h264 start is fully deferred");
        map.set(true, true); Mh2pVideoGate.poll(active, wrapper);
        check(Mh2pVideoGate.isReady(), "both stock readiness signals release gate");
        check(active.calls.toString().equals("prepare capture=h264 mode=fill zoomX=1.1;resume;"), "original prepare settings and resume replay in order");
        String replayed = active.calls.toString();
        Mh2pVideoGate.poll(active, wrapper);
        check(active.calls.toString().equals(replayed), "no duplicate replay");
        Mh2pVideoGate.poll(unplugged, wrapper);
        check(unplugged.calls.toString().equals("prepare capture=h264;stop;"), "unplug stops warm decoder and cancels stale resume");
        Mh2pVideoGate.poll(paused, wrapper);
        check(paused.calls.toString().equals("prepare capture=h264;"), "pause cancels pending resume");
        Mh2pVideoGate.poll(reconnect, wrapper);
        check(reconnect.calls.toString().equals("prepare capture=h264 mode=letter;stop;prepare capture=h264 mode=fill;resume;"), "fast reconnect releases only the new session resume");
        Mh2pVideoGate.poll(mirror, wrapper);
        check(mirror.calls.toString().equals("start capture=mirror mode=fill;"), "mirror start releases once after readiness");
        Mh2pVideoGate.send(active, "pause");
        Mh2pVideoGate.send(active, "stop");
        check(active.calls.toString().endsWith("resume;pause;stop;"), "post-ready pause/stop retain original path");
        map.set(false, false); Mh2pVideoGate.poll(active, wrapper);
        check(Mh2pVideoGate.isReady(), "boot latch remains ready after native map is hidden");
    }
}

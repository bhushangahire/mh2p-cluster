package de.audi.tghu.navi.app.map;
/** Host fixture; no Audi implementation is executed by tests. */
public class AbstractMap {
    protected volatile boolean mapDrawn;
    private boolean initialized;
    public boolean isInitialized() { return initialized; }
    public void set(boolean init, boolean drawn) { initialized = init; mapDrawn = drawn; }
}

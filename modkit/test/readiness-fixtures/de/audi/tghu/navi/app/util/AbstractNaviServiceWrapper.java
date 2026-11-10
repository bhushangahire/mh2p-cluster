package de.audi.tghu.navi.app.util;
public class AbstractNaviServiceWrapper {
    private Object service;
    public AbstractNaviServiceWrapper(Object s) { service = s; }
    protected Object get() { return service; }
}

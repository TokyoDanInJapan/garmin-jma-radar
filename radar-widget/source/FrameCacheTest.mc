using Toybox.Test;
using Toybox.Lang;

// Unit tests for FrameCache: the URL-keyed bitmap store, its retain() eviction,
// and the persistent (FrameStore) backing. String values stand in for bitmaps
// (the cache never inspects them). A FakeStore stands in for Application.Storage
// so these tests never touch real device storage. Run like the other (:test)
// suites:
//   monkeyc -f monkey.jungle -o bin/test.prg -y <dev_key> -d edge1040 --unit-test
//   monkeydo bin/test.prg edge1040 -t

// In-memory stand-in for FrameStore/Application.Storage. `full` models a full
// object store: every put() is rejected, exercising the best-effort fallback.
(:test)
class FakeStore {
    var m;
    var full = false;
    function initialize() { m = {}; }
    function get(key) { return m.get(key); }
    function put(key, value) {
        if (full) { return false; }
        m.put(key, value);
        return true;
    }
    function remove(key) { m.remove(key); }
}

(:test)
function testFrameCachePutGetMiss(logger) {
    var c = new FrameCache(null);
    c.put("/t?i=0", "B0");
    return c.get("/t?i=0").equals("B0")   // hit
        && c.get("/t?i=9") == null        // miss -> null
        && c.size() == 1;
}

(:test)
function testFrameCacheRetainKeepsListedDropsRest(logger) {
    var c = new FrameCache(null);
    c.put("a", "A"); c.put("b", "B"); c.put("c", "C");
    // "d" isn't cached; "a" isn't in the keep-list.
    var dropped = c.retain(["b", "c", "d"]);
    return dropped == 1 && c.size() == 2
        && c.get("a") == null
        && c.get("b").equals("B")
        && c.get("c").equals("C");
}

(:test)
function testFrameCacheRetainEmptyClearsAll(logger) {
    var c = new FrameCache(null);
    c.put("a", "A"); c.put("b", "B");
    var dropped = c.retain([]);
    return dropped == 2 && c.size() == 0 && c.get("a") == null;
}

(:test)
function testFrameCacheNullStoreIsInMemoryOnly(logger) {
    // No persistent backing -> get() never falls through to a store.
    var c = new FrameCache(null);
    c.put("a", "A");
    return c.get("a").equals("A") && c.size() == 1;
}

(:test)
function testFrameCachePersistsAcrossColdStart(logger) {
    var s = new FakeStore();
    var c1 = new FrameCache(s);
    c1.put("a", "A");
    // A fresh cache over the SAME store models a cold start: the in-memory tier
    // is gone, but the frame is served from -- and re-warmed from -- the store.
    var c2 = new FrameCache(s);
    return c2.get("a").equals("A") && c2.size() == 1;
}

(:test)
function testFrameCacheRetainPrunesStore(logger) {
    var s = new FakeStore();
    var c1 = new FrameCache(s);
    c1.put("a", "A"); c1.put("b", "B"); c1.put("c", "C");
    c1.retain(["b", "c"]);   // "a" is dropped from BOTH tiers
    var c2 = new FrameCache(s);   // cold start
    return c2.get("a") == null
        && c2.get("b").equals("B")
        && c2.get("c").equals("C");
}

(:test)
function testFrameCacheStorageFullFallsBackToMemory(logger) {
    var s = new FakeStore();
    s.full = true;                 // the object store rejects every write
    var c1 = new FrameCache(s);
    c1.put("a", "A");
    var memOk = c1.get("a").equals("A");   // in-memory still serves this session
    var c2 = new FrameCache(s);             // ...but nothing persisted
    return memOk && c2.get("a") == null;
}

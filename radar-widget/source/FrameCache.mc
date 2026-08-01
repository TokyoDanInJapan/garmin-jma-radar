using Toybox.Lang;

// Storage key under which the list of persisted tile URLs is kept, so retain()
// can evict stale persisted frames – Application.Storage offers no way to
// enumerate keys. Deliberately unlike any tile URL (those start with "/tile" or
// "http"), so it can't collide with a frame entry.
const FRAME_CACHE_INDEX_KEY = "__frameCacheIndex__";

// Cache of decoded frame bitmaps, keyed by the frame's tile URL, over two tiers:
// a live in-memory map and an optional persistent backing (FrameStore).
//
// The URL encodes zoom, rounded lat/lon, basetime and validtime, so an identical
// URL is a byte-identical frame – which lets a reopened widget reuse a frame it
// already downloaded instead of pulling it again over the slow BLE image path
// (~30x slower than the data path, see FramePipeline).
//
// The two tiers cover two different "reopen" cases:
//   - In-memory (mMap): reuse within one app instance – a reload, a zoom
//     re-fetch, the detail-view push. Free: the bitmaps are the same objects the
//     pipeline already holds resident, so this adds no memory beyond live frames.
//   - Persistent (mStore, optional): reuse across a COLD START. Scrolling to
//     another widget in the carousel stops the app (frees mMap), so returning is
//     a cold start. Only Application.Storage spans that. It can hold decoded
//     bitmaps directly (see FrameStore), so no PNG-byte round-trip is needed.
//     Writes are best-effort – a full store just means that frame re-downloads.
//
// Bounded by retain(): each new frame list drops entries (both tiers) whose URL
// is no longer in the list – frames aged out of the -15..+60 window, or from a
// since-changed zoom/location. The cache therefore never holds more than the
// current frame count.
class FrameCache {
    hidden var mMap;     // in-memory: tile-URL String -> BitmapResource
    hidden var mStore;   // persistent backing (FrameStore) or null for memory-only

    function initialize(store) {
        mMap = {};
        mStore = store;
    }

    // In-memory hit first. On a miss fall back to the persistent store (the
    // cold-start path) and re-warm the in-memory tier so later gets are free.
    function get(url as Lang.String) {
        var v = mMap.get(url);
        if (v != null) { return v; }
        if (mStore != null) {
            v = mStore.get(url);
            if (v != null) { mMap.put(url, v); }
        }
        return v;
    }

    // Store in memory and, best-effort, persist so the frame survives a cold
    // start. If the store rejects it (full), drop the partial entry and stop
    // tracking the URL – the in-memory copy still serves this session.
    function put(url as Lang.String, bmp) as Void {
        mMap.put(url, bmp);
        if (mStore != null) {
            if (mStore.put(url, bmp)) {
                indexAdd(url);
            } else {
                mStore.remove(url);
                indexRemove(url);
            }
        }
    }

    // Keep only entries whose URL appears in `urls`. Drop the rest from BOTH
    // tiers (they've aged out of the useful window). Returns how many in-memory
    // entries were dropped.
    function retain(urls as Lang.Array<Lang.String>) as Lang.Number {
        var keep = {};
        for (var i = 0; i < urls.size(); i += 1) {
            var v = mMap.get(urls[i]);
            if (v != null) { keep.put(urls[i], v); }
        }
        var dropped = mMap.size() - keep.size();
        mMap = keep;
        if (mStore != null) { prune(urls); }
        return dropped;
    }

    function size() as Lang.Number {
        return mMap.size();
    }

    // ---- Persistent index (Application.Storage has no key enumeration) -------
    hidden function indexList() as Lang.Array {
        var idx = mStore.get(FRAME_CACHE_INDEX_KEY);
        return (idx == null) ? [] : idx;
    }

    hidden function indexAdd(url) as Void {
        var idx = indexList();
        if (idx.indexOf(url) < 0) {
            idx.add(url);
            mStore.put(FRAME_CACHE_INDEX_KEY, idx);
        }
    }

    hidden function indexRemove(url) as Void {
        var idx = indexList();
        if (idx.indexOf(url) >= 0) {
            idx.remove(url);
            mStore.put(FRAME_CACHE_INDEX_KEY, idx);
        }
    }

    // Delete persisted frames whose URL isn't in `urls`, and rewrite the index
    // to just the survivors.
    hidden function prune(urls as Lang.Array<Lang.String>) as Void {
        var idx = indexList();
        var keep = [];
        for (var i = 0; i < idx.size(); i += 1) {
            var u = idx[i];
            if (urls.indexOf(u) >= 0) {
                keep.add(u);
            } else {
                mStore.remove(u);
            }
        }
        mStore.put(FRAME_CACHE_INDEX_KEY, keep);
    }
}

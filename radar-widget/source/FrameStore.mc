using Toybox.Application;
using Toybox.Lang;
using Toybox.System;

// Fraction of total app memory that must remain FREE for a frame to be persisted
// (see put()). ~1/3 of the ~1MB heap comfortably covers serializing one decoded
// frame plus the frames already resident in heap.
const FRAME_STORE_FREE_FRACTION = 3;

// Persistent backing for FrameCache: a thin, best-effort wrapper over
// Application.Storage.
//
// Why this exists: the in-memory FrameCache is freed when the app is STOPPED,
// which is exactly what the Edge does when the user scrolls to another widget in
// the carousel -- the widget app is killed, not merely hidden, so returning to
// it is a cold start with an empty in-memory cache (that's why every reopen was
// re-downloading). Application.Storage survives that, and it CAN hold a decoded
// bitmap directly: Storage.ValueType includes WatchUi.BitmapResource /
// Graphics.BitmapReference (supported since SDK 3.0.1, below our 3.2.0 minimum),
// so there's no need to fetch/decode raw PNG bytes -- which the SDK can't do
// anyway (makeImageRequest returns an already-decoded bitmap; makeWebRequest has
// no binary response type).
//
// Every write is best-effort. Two ways it can fail, both handled by returning
// false so FrameCache falls back to the in-memory path (a missed persist just
// means that frame re-downloads next cold start -- never a crash):
//   - The object store is full -> setValue throws (caught).
//   - Not enough free memory. A decoded frame is large and on this device's
//     firmware a stored bitmap is loaded/serialized in the ~1MB app heap (not the
//     separate graphics pool), which already holds the resident frames. An
//     unguarded setValue there can hit an UNCATCHABLE Out-Of-Memory that crashes
//     and restarts the load -- which looked exactly like "every frame reloads on
//     reopen". So we persist only with comfortable headroom; this also self-limits
//     how many frames we cache to whatever actually fits.
class FrameStore {

    function get(key as Lang.String) {
        return Application.Storage.getValue(key);
    }

    // Persist a value. Returns true on success, false if skipped for low memory
    // or rejected by the store (full / unsupported) -- best-effort by contract.
    function put(key as Lang.String, value) as Lang.Boolean {
        var st = System.getSystemStats();
        // Guard the uncatchable OOM: require free heap above a safe margin before
        // handing a large bitmap to setValue.
        if (st.freeMemory < st.totalMemory / FRAME_STORE_FREE_FRACTION) {
            return false;
        }
        try {
            Application.Storage.setValue(key, value);
            return true;
        } catch (ex) {
            return false;
        }
    }

    function remove(key as Lang.String) as Void {
        try {
            Application.Storage.deleteValue(key);
        } catch (ex) {
            // Deleting a missing/na key is harmless; nothing to recover.
        }
    }
}

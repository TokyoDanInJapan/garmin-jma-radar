using Toybox.Communications;
using Toybox.Graphics;
using Toybox.WatchUi;
using Toybox.Lang;

// ---- Image pipeline tuning ---------------------------------------------------
const MAX_RETRIES = 3;      // per-frame retries; Garmin's image-fetch service 500s intermittently
// Transfer watchdog for the in-flight image request, expressed in master ticks
// (FRAME_MS each, and the view's tick timer drives FramePipeline.tick()). Over
// Bluetooth a request is proxied through the phone, and a hung/dropped transfer
// can fail to invoke its callback at all. The pipeline keeps exactly one request
// in flight and only the callback advances it, so a missing callback would
// freeze loading forever ("stuck on the first frame"). When a transfer has been
// outstanding past this limit we treat it as a transient failure, then retry.
//
// The limit is generous: makeImageRequest does not transfer the PNG directly –
// it's redirected through Garmin's image service, which is slow and flaky over
// BLE (the documented BLE_HOST_TIMEOUT). A successful image takes ~27s over
// Bluetooth in good conditions and in the field regularly exceeds 45s (a 45s
// limit left rides with most frames abandoned mid-transfer and only their
// salvaged stragglers showing). Aborting early is doubly harmful: the
// replacement request competes with the still-streaming abandoned transfer on
// the one BLE link, slowing both. So the window must comfortably cover a slow
// – but healthy – transfer. The watchdog is only there to recover from a
// transfer that is truly dead (callback never fires). Retry on timeout, since
// the BLE image path is intermittent and a fresh request often catches a good
// moment.
const IMAGE_TIMEOUT_TICKS = 180; // 180 * FRAME_MS = 90000 ms
// Requested frame size in px. Fills the Edge 1030 width (282px). This is a
// cross-project contract: it must match DEVICE_TILE_SIZE in proxy/src/index.js
// (what /tile renders) and in the speed-test widget (so its timings mirror ours).
const DEVICE_TILE_SIZE = 288;
// ------------------------------------------------------------------------------

// Production transport for FramePipeline: one Communications.makeImageRequest
// per fetch. Injected in RadarView. Unit tests inject a fake fetcher instead,
// which is what makes the pipeline's retry/epoch/single-flight logic testable
// without a network stack (see FramePipelineTest.mc).
class CommsImageFetcher {
    function fetch(url as Lang.String, params as Lang.Dictionary, options as Lang.Dictionary, cb as ImageCallback) as Void {
        Communications.makeImageRequest(url, params, options, cb.method(:onDone));
    }
}

// Single-flight downloader for the radar frame images. Owns everything between
// "here is the ordered frame URL list" (start) and "bitmap i is ready"
// (isFrameLoaded/frameAt): issuing one request at a time, retrying transient
// failures, recovering from hung transfers via the tick-driven watchdog, and
// classifying late callbacks by generation/epoch – salvaging a late success's
// bitmap while keeping it away from the single-flight bookkeeping.
//
// Single-flight because the Edge fetches images over Bluetooth via the phone –
// one shared link – so exactly one request is outstanding at a time. A burst
// of simultaneous makeImageRequest() calls overruns that link and frames get
// dropped. New frames are requested first, retries after (see pumpRequests).
//
// The pipeline owns no timers (Connect IQ caps concurrent Timer objects at ~3):
// the listener (RadarView) drives tick() from its master timer and is notified
// after every completion via onPipelineChanged().
class FramePipeline {

    hidden var mListener;      // notified via onPipelineChanged() after each completion
    hidden var mFetcher;       // transport: fetch(url, params, options, cb)
    hidden var mCache;         // FrameCache: url -> bitmap, reused across loads/reopens
    hidden var mProxyBase = "";
    hidden var mProxyKey = "";
    // Frame bitmaps, parallel to mFrameUrls. null until each loads. Held as a
    // plain Array so tests can stand in any object for a bitmap.
    hidden var mFrames as Lang.Array?;
    hidden var mFrameUrls as Lang.Array<Lang.String>?;
    hidden var mInflightIndex = -1; // frame index of the in-flight request (-1 = none)
    hidden var mLoadedCount = 0;    // how many bitmaps have arrived
    hidden var mNextRequest = 0;    // index of the next frame URL to request
    hidden var mInflight = 0;       // image requests currently in flight (0 or 1)
    hidden var mLastCode = 0;       // last non-200 code (0 = none yet, or a watchdog timeout)
    hidden var mRetryQueue as Lang.Array<Lang.Number> = []; // frame indices awaiting a retry
    hidden var mAttempts as Lang.Array<Lang.Number> = [];   // retry attempts used per frame
    // Per-frame "gave up" flags, parallel to mFrames: true once a frame is out
    // of retries (or failed with a non-retryable code) and won't be attempted
    // again. Drives the red cells in the view's progress bar. Cleared if a
    // salvaged late arrival fills the frame after all – loaded wins.
    hidden var mFailed as Lang.Array?;
    // Correlates an image callback with the request that started it.
    // makeImageRequest's callback carries no context, so each request captures
    // the current generation + epoch at issue time (see ImageCallback), and
    // onFrameImage classifies the completion by comparing them:
    //
    // mGeneration identifies the FRAME LIST (bumped on every reset, so on every
    // reload/zoom change). A callback from an older generation refers to frame
    // indices of a list we no longer hold – it is meaningless now and dropped.
    //
    // mEpoch identifies the ATTEMPT within a generation (bumped when the
    // watchdog abandons a request). A late callback carrying an old epoch must
    // not touch the single-flight bookkeeping – that now belongs to the
    // replacement request. Accepting it as a normal completion would corrupt
    // the counts and stall the load. But within the same generation its PAYLOAD
    // is still exactly right for its frame (tile URLs are immutable per
    // basetime/validtime), so a late 200 is salvaged into mFrames. Over BLE
    // this is the difference between working and never loading: a healthy
    // transfer regularly outlives the watchdog, and discarding those late PNGs
    // meant every attempt was aborted at the deadline and its eventual arrival
    // thrown away.
    hidden var mGeneration = 0;
    hidden var mEpoch = 0;
    hidden var mAwaiting = false;   // true while one image request is outstanding
    hidden var mAwaitTicks = 0;     // ticks the in-flight transfer has waited (watchdog)
    hidden var mPumping = false;    // re-entrancy guard (synchronous-callback recursion)

    // store is the FrameCache's persistent backing (a FrameStore), or null for an
    // in-memory-only cache. Injected like the fetcher so unit tests stay off
    // Application.Storage (a real store would leak persisted frames across tests).
    function initialize(listener, fetcher, store) {
        mListener = listener;
        mFetcher = fetcher;
        mCache = new FrameCache(store);
    }

    // ---- State queries (the view renders from these) ------------------------
    function hasFrames() {
        return mFrames != null;
    }

    function size() {
        return (mFrames != null) ? mFrames.size() : 0;
    }

    function frameAt(i) {
        return (mFrames != null && i >= 0 && i < mFrames.size()) ? mFrames[i] : null;
    }

    function isFrameLoaded(i) {
        return frameAt(i) != null;
    }

    // True once frame i has permanently failed (out of retries / non-retryable
    // code) – unless a salvaged late arrival filled it after all.
    function isFrameFailed(i) {
        return mFailed != null && i >= 0 && i < mFailed.size() && mFailed[i] == true;
    }

    function loadedCount() {
        return mLoadedCount;
    }

    function lastCode() {
        return mLastCode;
    }

    // A transfer is in flight -> the view's busy indicator animates and the
    // watchdog counts against it.
    function isAwaiting() {
        return mAwaiting;
    }

    // Frame index of the image currently being fetched, or -1 when none is in
    // flight.
    function inflightIndex() {
        return mAwaiting ? mInflightIndex : -1;
    }

    // Every request attempted: none in flight, none queued or pending retry.
    function done() {
        return mFrames != null && mInflight == 0
            && mNextRequest >= mFrameUrls.size() && mRetryQueue.size() == 0;
    }

    // ---- Lifecycle -----------------------------------------------------------
    // Back to "no frames, nothing in flight". Bumping the generation invalidates
    // any image callback still in flight from the old pipeline entirely (its
    // frame index refers to a list we no longer hold, so not even its payload
    // can be salvaged). The frame cache is deliberately NOT cleared here – it
    // outlives a reload/reopen so start() can reuse its bitmaps.
    function reset() {
        mFrames = null;
        mFrameUrls = null;
        mInflightIndex = -1;
        mLoadedCount = 0;
        mNextRequest = 0;
        mInflight = 0;
        mLastCode = 0;
        mRetryQueue = [];
        mAttempts = [];
        mFailed = null;
        mGeneration += 1;
        mEpoch += 1;
        mAwaiting = false;
        mAwaitTicks = 0;
    }

    // Begin fetching an ordered list of frame URLs (as returned by /frames:
    // "/tile?..." paths relative to proxyBase). Frames already in the cache
    // (from a prior load, for example, before the widget was reopened) are reused
    // immediately instead of being re-fetched over BLE.
    function start(urls as Lang.Array<Lang.String>, proxyBase as Lang.String, proxyKey as Lang.String) {
        reset();
        // Evict cached frames that aren't in this list – they've aged out of the
        // useful window (or the zoom/location changed). Keeps the cache bounded
        // to the current frame count.
        mCache.retain(urls);
        mProxyBase = proxyBase;
        mProxyKey = proxyKey;
        mFrameUrls = urls;
        mFrames = new [urls.size()];
        mAttempts = new [urls.size()];
        mFailed = new [urls.size()];
        for (var i = 0; i < urls.size(); i += 1) {
            mAttempts[i] = 0;
            mFailed[i] = false;
            // Cache hit -> reuse the already-decoded bitmap. pumpRequests then
            // skips it (no fetch). This is what makes a reopen instant.
            var cached = mCache.get(urls[i]);
            if (cached != null) {
                mFrames[i] = cached;
                mLoadedCount += 1;
            }
        }
        pumpRequests();
        // Reflect any cache hits right away: if every frame came from the cache
        // there are no fetch callbacks to trigger a repaint.
        mListener.onPipelineChanged();
    }

    // Watchdog, driven by the view's master tick timer (one call per FRAME_MS).
    // Fires at most once per stuck request: timedOut() clears mAwaiting.
    function tick() {
        if (!mAwaiting) { return; }
        mAwaitTicks += 1;
        if (mAwaitTicks >= IMAGE_TIMEOUT_TICKS) {
            mAwaitTicks = 0;
            timedOut();
        }
    }

    // ---- Internals -----------------------------------------------------------
    // The in-flight request hasn't called back within the budget (a hung BLE
    // transfer). Treat it as a transient transport failure so the pipeline
    // recovers instead of freezing on the first frame. Code 0 -> retryable. The
    // re-queued retry usually succeeds fast off the proxy's warm cache.
    function timedOut() {
        if (mFrames == null || mFrameUrls == null) { return; }
        if (!mAwaiting) { return; }
        mAwaiting = false;
        // Abandon this request. The transfer may still be alive over BLE and
        // call back later. Bump the epoch so that late callback (carrying the
        // old epoch) can't be mis-mapped onto the replacement request we're
        // about to issue – its bitmap is salvaged instead (see onFrameImage).
        mEpoch += 1;
        finishImage(mInflightIndex, 0, null);
    }

    // Issue requests while none is in flight: new frames first, retries after.
    // An already-loaded frame is never fetched – whether it came from the cache
    // (a reopen) or was filled by a salvaged late arrival while it still sat in
    // the retry queue. Re-fetching a frame that's already on screen would waste
    // a slow BLE transfer and keep the loading bar blinking after the frame is
    // shown (the "loops through loading, rotates continuously" symptom).
    //
    // Re-entrancy + recursion guard: makeImageRequest can invoke its callback
    // SYNCHRONOUSLY (notably an immediate failure when the BLE link is down), so
    // onFrameImage -> finishImage -> pumpRequests can run inside
    // requestFrameImage. Left unchecked that recurses for every queued
    // frame/retry and overflows the stack on-device. mPumping turns it into a
    // loop: the nested call returns immediately and this frame issues the next
    // request. mInflight is bumped BEFORE the request so a synchronous callback
    // decrements it back to 0 and the loop advances. An async request leaves it
    // at 1 and the loop exits.
    function pumpRequests() {
        if (mFrameUrls == null) { return; }
        if (mPumping) { return; }   // a synchronous callback re-entered, so let the loop below continue
        mPumping = true;
        while (mInflight == 0
                && (mRetryQueue.size() > 0 || mNextRequest < mFrameUrls.size())) {
            var index;
            // New frames first, retries after. Over BLE an abandoned transfer
            // is often still alive on the link. Immediately re-requesting the
            // SAME frame competes with its own zombie stream. Deferring retries
            // gives every frame a first attempt while earlier transfers drain –
            // and a late success is salvaged anyway (see onFrameImage).
            if (mNextRequest < mFrameUrls.size()) {
                index = mNextRequest;
                mNextRequest += 1;
            } else {
                index = mRetryQueue[0];
                mRetryQueue = mRetryQueue.slice(1, null);   // pop the head
            }
            // Skip anything we already have – a cache hit (new frame) or a
            // frame filled by a salvaged late arrival while it sat in the retry
            // queue. Popping it here drains the queue without a wasteful re-fetch.
            if (mFrames[index] != null) { continue; }
            mInflight += 1;
            requestFrameImage(index);
        }
        mPumping = false;
    }

    // Fetch one composited PNG frame.
    function requestFrameImage(index) {
        // The proxy returns frame URLs with the tile params already in a query
        // string (for example, "/tile?lat=..&basetime=.."). makeImageRequest does NOT
        // accept a query string embedded in the URL, so split it out into the
        // params dictionary (Util.queryToParams), which serialises properly.
        var raw  = mFrameUrls[index];
        var path = raw;
        var params = {} as Lang.Dictionary;
        var q = raw.find("?");
        if (q != null) {
            path = raw.substring(0, q);
            params = Util.queryToParams(raw.substring(q + 1, raw.length()));
        }
        params.put("key", mProxyKey); // proxy also accepts X-Proxy-Key
        var url = mProxyBase + path;
        var options = {
            :maxWidth => DEVICE_TILE_SIZE,
            :maxHeight => DEVICE_TILE_SIZE,
            // Proxy already delivers a 256-colour palette PNG. Don't re-dither.
            :dithering => Communications.IMAGE_DITHERING_NONE
        };
        // Arm the watchdog before firing: if the callback never returns (hung
        // phone link), tick()'s count recovers the pipeline. The callback
        // wrapper captures this frame's index and the current epoch, so the
        // completion maps to the right frame directly (no FIFO guessing) and a
        // stale callback from an abandoned request is rejected.
        mInflightIndex = index;
        mAwaiting = true;
        mAwaitTicks = 0;
        var cb = new ImageCallback(self, index, mGeneration, mEpoch);
        mFetcher.fetch(url, params, options, cb);
    }

    // Callback for one image request (via ImageCallback): store the bitmap or
    // re-queue a retryable failure, and keep the pipeline pumping. See the
    // mGeneration/mEpoch comment for how stale callbacks are classified.
    function onFrameImage(index as Lang.Number, generation as Lang.Number, epoch as Lang.Number, code as Lang.Number, data) as Void {
        // A reset (reload/zoom change) may have torn the pipeline down while
        // this request was still in flight over BLE. Ignore the now-stale
        // callback instead of dereferencing the torn-down state, which crashed
        // on-device with an "Unexpected Type Error". A generation mismatch is
        // the same situation after a new list already started: the index refers
        // to the OLD list, so not even the payload is usable.
        if (mFrames == null || mFrameUrls == null) { return; }
        if (generation != mGeneration) { return; }
        if (epoch != mEpoch) {
            // Same frame list, but the watchdog abandoned this request and its
            // single-flight slot now belongs to the replacement. The payload is
            // still exactly frame `index`, though (tile URLs are immutable per
            // basetime/validtime) – and over BLE a healthy transfer regularly
            // outlives the watchdog, so discarding it means "phone" loads never
            // complete. Salvage the bitmap. Leave the bookkeeping alone.
            if (code == 200 && data != null && mFrames[index] == null) {
                mFrames[index] = data;
                mLoadedCount += 1;
                mFailed[index] = false;   // it made it after all, so un-redden its bar cell
                mCache.put(mFrameUrls[index], data);
                mListener.onPipelineChanged();
            }
            return;
        }
        // The watchdog may already have given this request up (treated it as a
        // timeout). Ignore the late callback so we don't double-count mInflight.
        if (!mAwaiting) { return; }
        mAwaiting = false;
        finishImage(index, code, data);
    }

    // Shared completion path, reached either from the callback (onFrameImage)
    // or the watchdog (timedOut). The index is the frame this completion
    // belongs to (captured per-request). Notifies the listener last, so it
    // observes the post-pump state.
    function finishImage(index as Lang.Number, code as Lang.Number, data) as Void {
        if (mInflight > 0) { mInflight -= 1; }
        mInflightIndex = -1;

        if (code == 200 && data != null) {
            // The frame may already be filled by a salvaged late arrival from
            // an abandoned attempt. Don't double-count it.
            if (mFrames[index] == null) {
                mFrames[index] = data;     // BitmapResource
                mLoadedCount += 1;
                mCache.put(mFrameUrls[index], data);   // reuse on a future reopen
            }
        } else if (code != 200) {
            mLastCode = code;          // remember why a tile failed (429/5xx/...)
            // Re-queue transient failures so one flaky image fetch doesn't
            // permanently drop a frame.
            if (Util.isRetryable(code) && mAttempts[index] < MAX_RETRIES) {
                mAttempts[index] += 1;
                mRetryQueue.add(index);
            } else {
                // Out of retries (or a non-retryable code): this frame won't
                // be attempted again. The view shows its bar cell red. A
                // salvaged late arrival can still fill – and clear – it.
                mFailed[index] = true;
            }
        }
        pumpRequests();
        mListener.onPipelineChanged();
    }
}

// Per-request wrapper for the image fetch. makeImageRequest's callback
// signature is fixed at (responseCode, data) with no context, so we bind the
// frame index and the epoch at request time and pass them back to the pipeline.
// The epoch lets the pipeline reject a callback from a request it already
// abandoned (watchdog timeout) or superseded (reload/zoom) – without it, a
// slow-but-alive BLE transfer calling back late would be mistaken for the
// current request and stall the load. See FramePipeline.mEpoch.
class ImageCallback {
    hidden var mPipeline;
    hidden var mIndex;
    hidden var mGeneration;
    hidden var mEpoch;

    function initialize(pipeline, index, generation, epoch) {
        mPipeline = pipeline;
        mIndex = index;
        mGeneration = generation;
        mEpoch = epoch;
    }

    function onDone(code as Lang.Number, data as Graphics.BitmapReference or WatchUi.BitmapResource or Null) as Void {
        mPipeline.onFrameImage(mIndex, mGeneration, mEpoch, code, data);
    }
}

using Toybox.Test;
using Toybox.Lang;

// Unit tests for FramePipeline: the single-flight / retry / epoch / watchdog
// logic, driven through a fake fetcher instead of Communications. This is the
// logic that used to live untestable inside RadarView. Extracting it is what
// makes these tests possible. Run like UtilTest.mc:
//   monkeyc -f monkey.jungle -o bin/test.prg -y <dev_key> -d edge1040 --unit-test
//   monkeydo bin/test.prg edge1040 -t

// Fake transport. Records every fetch. The test then either invokes the
// captured callback by hand (async mode) or, with syncCode set, responds from
// inside fetch() itself – which exercises the pipeline's synchronous-callback
// re-entrancy path (the mPumping guard).
(:test)
class FakeFetcher {
    var calls = [];        // one { :url, :params, :cb } per fetch, in order
    var syncCode = null;   // when set, respond synchronously with this code
    var syncData = null;   // ... and this payload

    function fetch(url, params, options, cb) {
        calls.add({ :url => url, :params => params, :cb => cb });
        if (syncCode != null) {
            cb.onDone(syncCode, syncData);
        }
    }

    function lastCb() {
        return calls[calls.size() - 1].get(:cb);
    }
}

// Fake listener: counts onPipelineChanged notifications.
(:test)
class FakeListener {
    var changes = 0;
    function onPipelineChanged() as Void {
        changes += 1;
    }
}

(:test)
function testPipelineSingleFlightAndUrlSplit(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/tile?a=1", "/tile?a=2", "/tile?a=3"], "https://proxy", "K");

    // Exactly ONE request in flight, for frame 0, with the query split into
    // params and the key added.
    if (f.calls.size() != 1) { return false; }
    if (!p.isAwaiting() || p.inflightIndex() != 0) { return false; }
    var c = f.calls[0];
    if (!c.get(:url).equals("https://proxy/tile")) { return false; }
    if (!c.get(:params).get("a").equals("1")) { return false; }
    if (!c.get(:params).get("key").equals("K")) { return false; }

    // Completing frame 0 pumps frame 1, and so on until done.
    f.lastCb().onDone(200, "BMP0");
    if (f.calls.size() != 2 || p.inflightIndex() != 1) { return false; }
    f.lastCb().onDone(200, "BMP1");
    f.lastCb().onDone(200, "BMP2");
    return p.done() && !p.isAwaiting()
        && p.loadedCount() == 3 && p.isFrameLoaded(2)
        && p.frameAt(0).equals("BMP0");
}

(:test)
function testPipelineSynchronousCallbacksDontRecurse(logger) {
    // A fetcher that succeeds from inside fetch() models makeImageRequest
    // invoking its callback synchronously. The mPumping guard must turn the
    // nested pump into a loop. All frames complete, one request each.
    var f = new FakeFetcher();
    f.syncCode = 200;
    f.syncData = "BMP";
    var l = new FakeListener();
    var p = new FramePipeline(l, f, null);
    p.start(["/t?i=0", "/t?i=1", "/t?i=2", "/t?i=3", "/t?i=4", "/t?i=5"], "https://proxy", "K");
    // 6 completion notifies + 1 from the end of start() (which reflects cache
    // hits, and here there are none, but the notify still fires).
    return f.calls.size() == 6 && p.loadedCount() == 6
        && p.done() && l.changes == 7;
}

(:test)
function testPipelineRetriesTransientFailure(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0"], "https://proxy", "K");

    // Two 500s -> re-queued and re-requested each time. Then a success lands.
    f.lastCb().onDone(500, null);
    if (f.calls.size() != 2) { return false; }
    f.lastCb().onDone(500, null);
    if (f.calls.size() != 3) { return false; }
    f.lastCb().onDone(200, "BMP");
    return p.done() && p.loadedCount() == 1 && p.lastCode() == 500;
}

(:test)
function testPipelineRetryBudgetExhausts(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0"], "https://proxy", "K");

    // Initial attempt + MAX_RETRIES retries, all failing -> the frame is
    // dropped (and flagged failed for the red bar cell) and the pipeline
    // finishes empty (no infinite retry loop).
    for (var i = 0; i <= MAX_RETRIES; i += 1) {
        if (p.isFrameFailed(0)) { return false; }   // not failed while retries remain
        f.lastCb().onDone(503, null);
    }
    return f.calls.size() == 1 + MAX_RETRIES
        && p.done() && p.loadedCount() == 0 && p.lastCode() == 503
        && p.isFrameFailed(0);
}

(:test)
function testPipelineNonRetryableDropsFrame(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0", "/t?i=1"], "https://proxy", "K");

    // A 404 is not retryable: frame 0 is dropped (flagged failed for the red
    // bar cell), the pump moves on to frame 1.
    f.lastCb().onDone(404, null);
    if (f.calls.size() != 2 || p.inflightIndex() != 1) { return false; }
    f.lastCb().onDone(200, "BMP1");
    return p.done() && p.loadedCount() == 1 && p.lastCode() == 404
        && !p.isFrameLoaded(0) && p.isFrameLoaded(1)
        && p.isFrameFailed(0) && !p.isFrameFailed(1);
}

(:test)
function testPipelineWatchdogAbandonsAndLateSuccessIsSalvaged(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0"], "https://proxy", "K");
    var staleCb = f.lastCb();

    // No callback arrives. The watchdog fires after IMAGE_TIMEOUT_TICKS and
    // re-queues the frame, so a replacement request goes out.
    for (var i = 0; i < IMAGE_TIMEOUT_TICKS; i += 1) { p.tick(); }
    if (f.calls.size() != 2 || !p.isAwaiting()) { return false; }

    // The abandoned transfer was slow, not dead (the normal case over BLE):
    // its late 200 is salvaged into the frame slot, but the single-flight
    // bookkeeping – which now belongs to the replacement – is untouched.
    staleCb.onDone(200, "LATE");
    if (p.loadedCount() != 1 || !p.isFrameLoaded(0) || !p.isAwaiting()) { return false; }

    // The replacement completing for the already-salvaged frame neither
    // double-counts nor overwrites it.
    f.lastCb().onDone(200, "DUP");
    return p.done() && p.loadedCount() == 1 && p.frameAt(0).equals("LATE");
}

(:test)
function testPipelineLateFailureIsIgnored(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0"], "https://proxy", "K");
    var staleCb = f.lastCb();

    // Watchdog abandons. The late callback is a FAILURE, so there's nothing to
    // salvage – it must not disturb the replacement either.
    for (var i = 0; i < IMAGE_TIMEOUT_TICKS; i += 1) { p.tick(); }
    staleCb.onDone(500, null);
    if (p.loadedCount() != 0 || !p.isAwaiting() || f.calls.size() != 2) { return false; }

    f.lastCb().onDone(200, "BMP");
    return p.done() && p.loadedCount() == 1;
}

(:test)
function testPipelineRetriesRunAfterRemainingFrames(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0", "/t?i=1"], "https://proxy", "K");

    // Frame 0 fails transiently. The retry must NOT go out immediately (over
    // BLE it would compete with its own zombie transfer): frame 1 gets its
    // first attempt, and only then is frame 0 retried.
    f.lastCb().onDone(500, null);
    if (!f.calls[1].get(:params).get("i").equals("1")) { return false; }
    f.lastCb().onDone(200, "B1");
    if (!f.calls[2].get(:params).get("i").equals("0")) { return false; }
    f.lastCb().onDone(200, "B0");
    return p.done() && p.loadedCount() == 2;
}

(:test)
function testPipelineSalvageClearsFailedFrame(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0"], "https://proxy", "K");
    var firstCb = f.lastCb();

    // Every attempt (initial + retries) hangs until the watchdog abandons it:
    // the frame ends up flagged failed (red bar cell), pipeline done and empty.
    for (var a = 0; a <= MAX_RETRIES; a += 1) {
        for (var i = 0; i < IMAGE_TIMEOUT_TICKS; i += 1) { p.tick(); }
    }
    if (!p.done() || !p.isFrameFailed(0) || p.loadedCount() != 0) { return false; }

    // The first attempt's transfer was slow, not dead: its arrival is salvaged
    // and the frame stops reading as failed – loaded wins.
    firstCb.onDone(200, "LATE");
    return p.loadedCount() == 1 && p.isFrameLoaded(0) && !p.isFrameFailed(0);
}

(:test)
function testPipelineDoesNotRefetchSalvagedFrame(logger) {
    // Regression: a watchdog-abandoned frame sits in the retry queue. Its slow
    // transfer then completes late and is salvaged (frame shown). The retry
    // queue entry must NOT trigger a re-fetch of the already-loaded frame –
    // that kept the loading bar blinking for minutes over BLE.
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0"], "https://proxy", "K");
    var cb1 = f.lastCb();                  // first attempt

    // Watchdog abandons -> requeue -> a replacement fetch goes out.
    for (var i = 0; i < IMAGE_TIMEOUT_TICKS; i += 1) { p.tick(); }
    if (f.calls.size() != 2) { return false; }

    // The first (abandoned) transfer arrives late and is salvaged.
    cb1.onDone(200, "LATE");
    if (p.loadedCount() != 1 || !p.isFrameLoaded(0)) { return false; }

    // The replacement times out too and re-queues the (now already-loaded)
    // frame. The pump must drain that entry WITHOUT a third fetch.
    for (var i = 0; i < IMAGE_TIMEOUT_TICKS; i += 1) { p.tick(); }
    return p.done() && p.loadedCount() == 1
        && f.calls.size() == 2;            // no re-fetch of the shown frame
}

(:test)
function testPipelineReusesCachedFramesOnReopen(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0", "/t?i=1"], "https://proxy", "K");
    // Complete both fetches. They get cached under their URLs.
    f.lastCb().onDone(200, "B0");
    f.lastCb().onDone(200, "B1");
    if (f.calls.size() != 2 || p.loadedCount() != 2) { return false; }

    // Reopen: the same frame list. Every frame is served from the cache – no
    // new fetches are issued, and the pipeline is loaded immediately.
    p.start(["/t?i=0", "/t?i=1"], "https://proxy", "K");
    return f.calls.size() == 2            // still 2: no new makeImageRequests
        && p.done() && p.loadedCount() == 2
        && p.frameAt(0).equals("B0") && p.frameAt(1).equals("B1");
}

(:test)
function testPipelineEvictsFramesNotInNewList(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0", "/t?i=1"], "https://proxy", "K");
    f.lastCb().onDone(200, "B0");
    f.lastCb().onDone(200, "B1");

    // New list shares only i=1 (i=0 aged out of the window, i=2 is new). i=1 is
    // reused from cache (no fetch). Only i=2 is fetched fresh.
    p.start(["/t?i=1", "/t?i=2"], "https://proxy", "K");
    if (f.calls.size() != 3) { return false; }     // one new fetch, for i=2
    if (!p.isFrameLoaded(0)) { return false; }     // i=1 came from cache
    f.lastCb().onDone(200, "B2");
    if (!(p.done() && p.loadedCount() == 2
          && p.frameAt(0).equals("B1") && p.frameAt(1).equals("B2"))) { return false; }

    // i=0 was evicted, so returning to it re-fetches (not served from cache).
    p.start(["/t?i=0"], "https://proxy", "K");
    return f.calls.size() == 4 && !p.isFrameLoaded(0);
}

(:test)
function testPipelineResetInvalidatesInFlightCallback(logger) {
    var f = new FakeFetcher();
    var p = new FramePipeline(new FakeListener(), f, null);
    p.start(["/t?i=0"], "https://proxy", "K");
    var staleCb = f.lastCb();

    // A reload/zoom change resets the pipeline while the request is in flight.
    p.reset();
    if (p.hasFrames() || p.isAwaiting() || p.size() != 0 || p.done()) { return false; }

    // The old request's late callback must be a no-op on the fresh state.
    staleCb.onDone(200, "STALE");
    if (p.hasFrames() || p.loadedCount() != 0 || f.calls.size() != 1) { return false; }

    // And once a NEW frame list has started (new generation), the old
    // callback's index refers to the old list – it must NOT be salvaged into
    // the new one (wrong zoom / wrong times).
    p.start(["/t?j=0"], "https://proxy", "K");
    staleCb.onDone(200, "CROSS");
    return p.loadedCount() == 0 && !p.isFrameLoaded(0) && p.isAwaiting();
}

using Toybox.Test;
using Toybox.Lang;

// Unit tests for FrameListClient: sequence numbers, the watchdog and response
// checks, driven through a fake transport. Run like the other (:test) suites.

(:test)
class FakeWebFetcher {
    var calls = [];   // one { :url, :params, :options, :cb } per fetch
    function fetch(url, params, options, cb) {
        calls.add({ :url => url, :params => params, :options => options, :cb => cb });
    }
    function cb(i) { return calls[i].get(:cb); }
}

(:test)
class FakeFrameListListener {
    var frames = null;
    var labels = null;
    var offsets = null;
    var failCode = null;
    var failMsg = null;
    var calls = 0;
    function onFrameList(f, l, o) as Void { frames = f; labels = l; offsets = o; calls += 1; }
    function onFrameListFailed(code, msg) as Void { failCode = code; failMsg = msg; calls += 1; }
}

(:test)
function testFrameListRequestShape(logger) {
    var f = new FakeWebFetcher();
    var c = new FrameListClient(new FakeFrameListListener(), f);
    c.request("https://p", "SECRET", 35.681236d, 139.767125d, 8, 3);
    var call = f.calls[0];
    var params = call.get(:params);
    return call.get(:url).equals("https://p/frames")
        && params.get("lat").equals("35.681") && params.get("lon").equals("139.767")
        && params.get("n") == 3
        && params.get("key") == null   // the key goes in the header, not the URL
        && call.get(:options).get(:headers).get("X-Proxy-Key").equals("SECRET")
        && c.isAwaiting();
}

(:test)
function testFrameListStaleResponseIgnored(logger) {
    var f = new FakeWebFetcher();
    var l = new FakeFrameListListener();
    var c = new FrameListClient(l, f);
    c.request("https://p", "K", 35d, 139d, 6, 3);   // old zoom
    c.request("https://p", "K", 35d, 139d, 8, 3);   // new zoom, sent at once
    f.cb(0).onDone(401, null);                       // the old request answers late
    if (l.calls != 0 || !c.isAwaiting()) { return false; }
    f.cb(1).onDone(200, { "frames" => ["/t?a"] });
    return l.calls == 1 && l.frames.size() == 1;
}

(:test)
function testFrameListWatchdogFailsOnceAndDropsLateReply(logger) {
    var f = new FakeWebFetcher();
    var l = new FakeFrameListListener();
    var c = new FrameListClient(l, f);
    c.request("https://p", "K", 35d, 139d, 8, 3);
    for (var i = 0; i < FRAMES_TIMEOUT_TICKS; i += 1) { c.tick(); }
    if (l.calls != 1 || l.failCode != 0 || c.isAwaiting()) { return false; }
    c.tick();
    f.cb(0).onDone(200, { "frames" => ["/t?a"] });
    return l.calls == 1;
}

(:test)
function testFrameListValidatesBody(logger) {
    var f = new FakeWebFetcher();
    var l = new FakeFrameListListener();
    var c = new FrameListClient(l, f);
    c.request("https://p", "K", 35d, 139d, 8, 3);
    f.cb(0).onDone(200, "not json");
    if (!l.failMsg.equals("Bad server response")) { return false; }
    c.request("https://p", "K", 35d, 139d, 8, 3);
    f.cb(1).onDone(200, { "frames" => [] });
    if (!l.failMsg.equals("No frames available")) { return false; }
    c.request("https://p", "K", 35d, 139d, 8, 3);
    f.cb(2).onDone(200, { "frames" => [1, 2] });
    return l.failMsg.equals("Bad server response");
}

(:test)
function testFrameListCapsFramesAndChecksLabels(logger) {
    var f = new FakeWebFetcher();
    var l = new FakeFrameListListener();
    var c = new FrameListClient(l, f);
    c.request("https://p", "K", 35d, 139d, 8, 2);
    f.cb(0).onDone(200, {
        "frames" => ["/a", "/b", "/c"],
        "labels" => ["10:00", "10:15", "10:30"],
        "offsets" => ["bad", 15, 30]
    });
    return l.frames.size() == 2 && l.labels.size() == 2 && l.offsets == null;
}

(:test)
function testFrameListHttpErrorPassesCode(logger) {
    var f = new FakeWebFetcher();
    var l = new FakeFrameListListener();
    var c = new FrameListClient(l, f);
    c.request("https://p", "K", 35d, 139d, 8, 3);
    f.cb(0).onDone(401, null);
    return l.failCode == 401 && l.failMsg == null && !c.isAwaiting();
}

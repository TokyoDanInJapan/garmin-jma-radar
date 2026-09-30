using Toybox.Communications;
using Toybox.Lang;
using Toybox.PersistedContent;

// Watchdog for the /frames request, in master ticks (FRAME_MS each). Over
// Bluetooth a request is proxied through the phone and a hung transfer can fail
// to invoke its callback at all. Without a guard that would hang "Loading
// radar..." forever. /frames is small JSON over makeWebRequest and returns
// quickly, so it only needs a short "dead link" guard. (The image requests have
// their own, much longer watchdog – see FramePipeline.mc.)
const FRAMES_TIMEOUT_TICKS = 30; // 30 * FRAME_MS = 15000 ms

// Production transport for FrameListClient: one Communications.makeWebRequest
// per fetch. Unit tests inject a fake instead (see FrameListClientTest.mc).
class CommsWebFetcher {
    function fetch(url as Lang.String, params as Lang.Dictionary, options as Lang.Dictionary, cb as FrameListCallback) as Void {
        Communications.makeWebRequest(url, params, options, cb.method(:onDone));
    }
}

// Step 1 of a load: ask the proxy for the ordered frame URL list (/frames),
// check the answer, and hand it to the listener:
//   onFrameList(frames, labels, offsets)   labels/offsets may be null
//   onFrameListFailed(code, message)       message null -> derive from code
//
// Each request carries a sequence number, and only the newest one's callback
// counts. A plain "awaiting" flag was not enough: reload() clears it and then
// requests again at once from the last-known fix, so the OLD request's late
// callback passed the check. Frames for the old zoom then showed under the new
// zoom button, and an old 401 could flag a key that had since been fixed.
class FrameListClient {
    hidden var mListener;
    hidden var mFetcher;
    hidden var mSeq = 0;
    hidden var mAwaiting = false;
    hidden var mAwaitTicks = 0;
    hidden var mMax = 0;

    function initialize(listener, fetcher) {
        mListener = listener;
        mFetcher = fetcher;
    }

    function isAwaiting() as Lang.Boolean {
        return mAwaiting;
    }

    // Forget any request in flight. Its callback, if it ever comes, is ignored.
    function cancel() as Void {
        mSeq += 1;
        mAwaiting = false;
        mAwaitTicks = 0;
    }

    // Request up to n frames around (lat, lon) at zoom z. The key goes in the
    // X-Proxy-Key header rather than the query string, so it stays out of
    // request-URL logs. (Image requests can't set headers, so /tile still
    // carries ?key=.)
    function request(base as Lang.String, key as Lang.String, lat, lon, z as Lang.Number, n as Lang.Number) as Void {
        cancel();
        mAwaiting = true;
        mMax = n;
        var params = {
            "lat" => Util.coordStr(lat),
            "lon" => Util.coordStr(lon),
            "z"   => z,
            "n"   => n
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :headers => { "X-Proxy-Key" => key }
        };
        mFetcher.fetch(base + "/frames", params, options, new FrameListCallback(self, mSeq));
    }

    // Watchdog, driven by the view's master tick. Fires at most once per request.
    function tick() as Void {
        if (!mAwaiting) { return; }
        mAwaitTicks += 1;
        if (mAwaitTicks >= FRAMES_TIMEOUT_TICKS) {
            cancel();
            mListener.onFrameListFailed(0, null);
        }
    }

    function onResponse(seq as Lang.Number, code as Lang.Number, data) as Void {
        if (seq != mSeq || !mAwaiting) { return; }   // superseded, cancelled or timed out
        mAwaiting = false;
        if (code != 200) {
            mListener.onFrameListFailed(code, null);
            return;
        }
        if (!(data instanceof Lang.Dictionary)) {
            mListener.onFrameListFailed(code, "Bad server response");
            return;
        }
        var raw = data.get("frames");
        var frames = Util.frameList(raw, mMax);
        if (frames == null) {
            var empty = (raw instanceof Lang.Array) && raw.size() == 0;
            mListener.onFrameListFailed(code, empty ? "No frames available" : "Bad server response");
            return;
        }
        var n = frames.size();
        // Labels and offsets are optional (an older proxy sends neither), so a
        // bad one only hides the label instead of failing the load.
        mListener.onFrameList(frames, Util.perFrame(data.get("labels"), n, false),
            Util.perFrame(data.get("offsets"), n, true));
    }
}

// Binds a sequence number to one /frames request, since the makeWebRequest
// callback carries no context of its own.
class FrameListCallback {
    hidden var mClient;
    hidden var mSeq;

    function initialize(client, seq) {
        mClient = client;
        mSeq = seq;
    }

    function onDone(code as Lang.Number, data as Lang.Dictionary or Lang.String or PersistedContent.Iterator or Null) as Void {
        mClient.onResponse(mSeq, code, data);
    }
}

using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Communications;
using Toybox.Timer;
using Toybox.Application;
using Toybox.System;
using Toybox.Lang;
using Toybox.PersistedContent;

// ---- CONFIG ----------------------------------------------------------------
const TICK_MS      = 100;    // master tick: drives the live clock + scheduling
const GAP_TICKS    = 10;     // idle gap between test cycles (10 * 100ms = 1s)
const TIMEOUT_MS   = 90000;  // abandon a request that hasn't called back by here.
                             // Matches the radar widget's IMG watchdog: a healthy
                             // image transfer over BLE can outlive 45s, so a
                             // shorter budget would record a false timeout.
const MAX_CYCLES   = 5;      // run exactly this many WEB+IMG cycles, then stop
                             // (tap to reset stats and re-run). Bounds a run so
                             // the averages settle instead of drifting forever.
const TEST_LAT     = 35.681; // fixed location (Tokyo); the test isn't location-specific
const TEST_LON     = 139.767;
const TEST_Z       = 10;
// Requested image size: the same the radar widget uses, so the timings mirror
// it. A cross-project contract – must match DEVICE_TILE_SIZE in the radar
// widget's FramePipeline.mc and in proxy/src/index.js.
const DEVICE_TILE_SIZE = 288;

// Test phases. A cycle runs WEB then IMG, so exactly one request is ever in
// flight (single-flight) – which is what lets mStartMs be shared across both
// phases instead of tracked per-request.
const PH_IDLE = 0;
const PH_WEB  = 1;  // makeWebRequest /frames      (the path that works over BLE)
const PH_IMG  = 2;  // makeImageRequest /speedtest (routed via Garmin's image service)
// ----------------------------------------------------------------------------

// Proxy Speed Test: runs up to MAX_CYCLES timed cycles, each a /frames JSON
// fetch (makeWebRequest) then an image fetch of the proxy's fixed /speedtest
// asset (makeImageRequest), and shows the results live – including a per-path
// running average that settles as the cycles complete – so you can watch the
// two transport paths' performance and which one stalls. Built to characterise
// the radar's Bluetooth problem: over BLE the image path goes via Garmin's
// image service and is ~30x slower than the raw data path. The /speedtest
// asset is deterministic and byte-identical on every pull (a real /tile frame
// varies in size with the weather), so IMG timings are comparable across runs.
// The image is never drawn. It's only a payload to time. Tap resets the stats
// and starts a fresh run.
class SpeedTestView extends WatchUi.View {

    hidden var mProxyBase;
    hidden var mProxyKey;

    hidden var mTick;             // single periodic timer (Timer), null when stopped
    hidden var mPhase = PH_IDLE;  // PH_IDLE / PH_WEB / PH_IMG
    hidden var mStartMs = 0;      // System.getTimer() when the in-flight request began
    hidden var mIdleTicks = 0;    // ticks waited since going idle (paces the next cycle)
    // Sequence number of the request in flight. Each callback carries the number
    // of the request that started it (SpeedCallback), and only the current one
    // counts. A flag alone was not enough: after a tap or a timeout the next
    // request starts within a second, so an old request's late callback passed
    // the check and was recorded against the new one, with the wrong phase and
    // a time measured from the wrong start.
    hidden var mSeq = 0;
    hidden var mCycles = 0;
    hidden var mSettingsMsg = null; // why the settings can't work, or null

    // Per-path stats: n=attempts, ok=200s, last ms + last code, and min/avg/max
    // over successful pulls (avg = sum/ok). min = -1 until the first success.
    hidden var mWebN = 0, mWebOk = 0, mWebLast = 0, mWebCode = 0, mWebMin = -1, mWebMax = 0, mWebSum = 0;
    hidden var mImgN = 0, mImgOk = 0, mImgLast = 0, mImgCode = 0, mImgMin = -1, mImgMax = 0, mImgSum = 0;

    hidden var mW = 0;
    hidden var mH = 0;

    function initialize() {
        View.initialize();
        readSettings();
    }

    function onLayout(dc) {
        mW = dc.getWidth();
        mH = dc.getHeight();
    }

    function readSettings() {
        // Both keys have a default in resources/shared/properties.xml, so getValue
        // never returns null here – read directly (no nullable fallback needed).
        mProxyBase = Util.stripSlash(Application.Properties.getValue("proxyBase").toString());
        mProxyKey  = Application.Properties.getValue("proxyKey").toString();
        mSettingsMsg = Util.settingsError(mProxyBase, mProxyKey);
    }

    // New settings make the old numbers meaningless, so start a fresh run.
    function onSettingsChanged() {
        readSettings();
        if (mTick != null) { resetStats(); }
    }

    function onShow() {
        resetStats();   // each showing starts a fresh MAX_CYCLES run
    }

    // Stop the timer and drop the request in flight, so nothing keeps running
    // while the widget is off-screen.
    function onHide() {
        stopTick();
        abandon();
    }

    // Clear all collected stats and start a fresh run on the next tick. Bound to
    // a tap (see the delegate), and used by onShow – so a tap both resets the
    // numbers and re-runs the bounded MAX_CYCLES pass.
    function resetStats() as Void {
        abandon();
        mCycles = 0;
        mIdleTicks = GAP_TICKS;   // start the first cycle on the next tick
        mWebN = 0; mWebOk = 0; mWebLast = 0; mWebCode = 0; mWebMin = -1; mWebMax = 0; mWebSum = 0;
        mImgN = 0; mImgOk = 0; mImgLast = 0; mImgCode = 0; mImgMin = -1; mImgMax = 0; mImgSum = 0;
        // Nothing to run without usable settings, so don't tick.
        if (mSettingsMsg == null) { startTick(); } else { stopTick(); }
        WatchUi.requestUpdate();
    }

    // Abandon the request in flight: bump the sequence number so its callback
    // is ignored, and cancel it so it stops using the one BLE link that the next
    // measurement needs. The bump comes first, in case the cancel calls the
    // callback straight away.
    hidden function abandon() as Void {
        var busy = (mPhase != PH_IDLE);
        mSeq += 1;
        mPhase = PH_IDLE;
        if (busy) { Communications.cancelAllRequests(); }
    }

    hidden function startTick() as Void {
        if (mTick == null) {
            mTick = new Timer.Timer();
            mTick.start(method(:onTick), TICK_MS, true);
        }
    }

    hidden function stopTick() as Void {
        if (mTick != null) { mTick.stop(); mTick = null; }
    }

    // ---- Master tick -------------------------------------------------------
    // Repaints for the live clock, paces the gap between cycles, and acts as the
    // watchdog for an in-flight request that never calls back.
    function onTick() as Void {
        if (mPhase == PH_IDLE) {
            // Run finished: the "done" screen is static, so stop the timer
            // until a tap/onShow resets.
            if (mCycles >= MAX_CYCLES) {
                stopTick();
                WatchUi.requestUpdate();
                return;
            }
            mIdleTicks += 1;
            if (mIdleTicks >= GAP_TICKS) {
                mCycles += 1;
                startWeb();
            }
        } else if (System.getTimer() - mStartMs >= TIMEOUT_MS) {
            // No callback within the budget: record a timeout (code 0) and move
            // on. abandon() makes the eventual late callback a no-op.
            var wasImg = (mPhase == PH_IMG);
            abandon();
            record(wasImg, TIMEOUT_MS, 0);
            mIdleTicks = 0;
        }
        WatchUi.requestUpdate();
    }

    // ---- Step 1: /frames via makeWebRequest --------------------------------
    // Sent like the radar sends it (key in the X-Proxy-Key header), so the WEB
    // timings match what the radar sees.
    function startWeb() as Void {
        mPhase = PH_WEB;
        mStartMs = System.getTimer();
        mSeq += 1;
        var url = mProxyBase + "/frames";
        var params = { "lat" => TEST_LAT, "lon" => TEST_LON, "z" => TEST_Z, "n" => 1 };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :headers => { "X-Proxy-Key" => mProxyKey }
        };
        Communications.makeWebRequest(url, params, options, new SpeedCallback(self, mSeq).method(:onWeb));
    }

    function onFrames(seq as Lang.Number, code as Lang.Number) as Void {
        if (seq != mSeq || mPhase != PH_WEB) { return; }   // abandoned: late, reset or timed out
        record(false, System.getTimer() - mStartMs, code);

        // Chain into the image pull. It fetches the fixed /speedtest asset, so
        // it needs nothing from the /frames response – run it even when the
        // WEB phase failed, so each path's stats accumulate independently.
        startImg();
    }

    // ---- Step 2: fixed /speedtest asset via makeImageRequest ----------------
    // The asset is deterministic and byte-identical on every pull (shaped like
    // a real frame: same dimensions and encoding, ~12 KB), so IMG timings
    // measure the transport, not the weather.
    function startImg() as Void {
        mPhase = PH_IMG;
        mStartMs = System.getTimer();
        mSeq += 1;

        var params = { "key" => mProxyKey }; // proxy also accepts X-Proxy-Key
        var options = {
            :maxWidth => DEVICE_TILE_SIZE,
            :maxHeight => DEVICE_TILE_SIZE,
            // Proxy already delivers a small palette PNG. Don't re-dither.
            :dithering => Communications.IMAGE_DITHERING_NONE
        };
        Communications.makeImageRequest(mProxyBase + "/speedtest", params, options,
            new SpeedCallback(self, mSeq).method(:onImg));
    }

    // The image itself is discarded – we only wanted the transfer time.
    function onImage(seq as Lang.Number, code as Lang.Number) as Void {
        if (seq != mSeq || mPhase != PH_IMG) { return; }   // abandoned: late, reset or timed out
        record(true, System.getTimer() - mStartMs, code);
        mPhase = PH_IDLE;
        mIdleTicks = 0;
        WatchUi.requestUpdate();
    }

    // ---- Stats -------------------------------------------------------------
    // Fold one completed (or timed-out) request into the running stats. isImg
    // picks which path's counters to update – the two paths share identical
    // bookkeeping, so a flag is cheaper than duplicating this block.
    function record(isImg as Lang.Boolean, ms as Lang.Number, code as Lang.Number) as Void {
        var ok = (code == 200);
        if (isImg) {
            mImgN += 1; mImgLast = ms; mImgCode = code;
            if (ok) {
                mImgOk += 1; mImgSum += ms;
                if (mImgMin < 0 || ms < mImgMin) { mImgMin = ms; }
                if (ms > mImgMax) { mImgMax = ms; }
            }
        } else {
            mWebN += 1; mWebLast = ms; mWebCode = code;
            if (ok) {
                mWebOk += 1; mWebSum += ms;
                if (mWebMin < 0 || ms < mWebMin) { mWebMin = ms; }
                if (ms > mWebMax) { mWebMax = ms; }
            }
        }
    }

    // ---- Render ------------------------------------------------------------
    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth();
        var cx = w / 2;
        var fT = dc.getFontHeight(Graphics.FONT_XTINY);
        var y = 6;

        // Title.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_SMALL, "Proxy Speed Test", Graphics.TEXT_JUSTIFY_CENTER);
        y += dc.getFontHeight(Graphics.FONT_SMALL) + 2;

        // Connection state + cycle progress (context for the numbers below).
        var phone = "?";
        var ds = System.getDeviceSettings();
        if (ds != null && (ds has :phoneConnected)) { phone = ds.phoneConnected ? "yes" : "NO"; }
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_XTINY,
            "phone " + phone + "   cycle " + mCycles + "/" + MAX_CYCLES,
            Graphics.TEXT_JUSTIFY_CENTER);
        y += fT + 6;

        // Big live status: which request is in flight and a running stopwatch,
        // or "done" once the run's cycle cap is reached (the averages below are
        // then final), or "idle" between cycles / before the first. Unusable
        // settings replace all of it with what to fix.
        if (mSettingsMsg != null) {
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, y, Graphics.FONT_SMALL, mSettingsMsg, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }
        var live;
        if (mPhase == PH_WEB) { live = "WEB  " + Util.secsStr(System.getTimer() - mStartMs); }
        else if (mPhase == PH_IMG) { live = "IMG  " + Util.secsStr(System.getTimer() - mStartMs); }
        else if (mCycles >= MAX_CYCLES) { live = "done"; }
        else { live = "idle"; }
        // FONT_MEDIUM (not a FONT_NUMBER_* face, which carries only digit glyphs
        // and would render the "WEB"/"IMG"/"done" letters as missing-glyph boxes).
        // Yellow while a request is in flight, green when the run is done, dim
        // grey when idle between cycles.
        var liveColour = Graphics.COLOR_DK_GRAY;
        if (mPhase != PH_IDLE) { liveColour = Graphics.COLOR_YELLOW; }
        else if (mCycles >= MAX_CYCLES) { liveColour = Graphics.COLOR_GREEN; }
        dc.setColor(liveColour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_MEDIUM, live, Graphics.TEXT_JUSTIFY_CENTER);
        y += dc.getFontHeight(Graphics.FONT_MEDIUM) + 8;

        // Per-path blocks. Stats are passed as one array [n, ok, last, code, min,
        // max, sum] to stay under Monkey C's per-method argument-count limit.
        y = drawBlock(dc, y, fT, "WEB /frames (makeWebRequest)", Graphics.COLOR_GREEN,
            [mWebN, mWebOk, mWebLast, mWebCode, mWebMin, mWebMax, mWebSum]);
        y += 4;
        y = drawBlock(dc, y, fT, "IMG /speedtest (makeImageRequest)", Graphics.COLOR_BLUE,
            [mImgN, mImgOk, mImgLast, mImgCode, mImgMin, mImgMax, mImgSum]);

        // Footer hint.
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, mH - fT - 4, Graphics.FONT_XTINY, "tap: reset + re-run",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // One stats block: coloured header, then "last/ok" and "avg/min/max" rows,
    // left-aligned. s = [n, ok, last, code, min, max, sum]. Returns the new y.
    function drawBlock(dc, y, fT, title, colour, s as Lang.Array<Lang.Number>) {
        var n = s[0], ok = s[1], last = s[2], code = s[3], mn = s[4], mx = s[5], sum = s[6];
        var x = 8;
        dc.setColor(colour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_XTINY, title, Graphics.TEXT_JUSTIFY_LEFT);
        y += fT;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        // Show the last code only when it isn't a 200, so failures stand out.
        var lastStr = (n == 0) ? "-" : (last + "ms" + ((code == 200) ? "" : (" c" + code)));
        dc.drawText(x, y, Graphics.FONT_XTINY, "last " + lastStr + "   ok " + ok + "/" + n,
            Graphics.TEXT_JUSTIFY_LEFT);
        y += fT;
        var avg = (ok > 0) ? (sum / ok) : 0;
        var mnStr = (mn < 0) ? "-" : (mn + "");
        dc.drawText(x, y, Graphics.FONT_XTINY,
            "avg " + avg + "  min " + mnStr + "  max " + mx + " ms",
            Graphics.TEXT_JUSTIFY_LEFT);
        y += fT;
        return y;
    }
}

// Binds a request's sequence number to its callback, since the Communications
// callbacks carry no context of their own.
class SpeedCallback {
    hidden var mView;
    hidden var mSeq;

    function initialize(view, seq) {
        mView = view;
        mSeq = seq;
    }

    function onWeb(code as Lang.Number, data as Lang.Dictionary or Lang.String or PersistedContent.Iterator or Null) as Void {
        mView.onFrames(mSeq, code);
    }

    function onImg(code as Lang.Number, data as Graphics.BitmapReference or WatchUi.BitmapResource or Null) as Void {
        mView.onImage(mSeq, code);
    }
}

using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Communications;
using Toybox.Position;
using Toybox.Timer;
using Toybox.Application;
using Toybox.Lang;
using Toybox.PersistedContent;
using Toybox.System;

// ---- CONFIG ----------------------------------------------------------------
// User-facing config (proxy URL, key, zoom, frame count) lives in app settings
// (resources/shared/settings.xml -> properties.xml), editable from Garmin Connect with
// no rebuild. Only the fixed playback tuning stays as consts here. The image
// pipeline's tuning (retries, transfer watchdog, tile size) lives with the
// pipeline in FramePipeline.mc.
const FRAME_MS = 500;       // ms per frame during playback, and the master tick interval
// Over Bluetooth each tile is ~30x slower (Garmin's image service), so cap the
// number of frames fetched to keep the animation usable. On Wi-Fi (the fast
// direct path) we load the full frameCount setting. See effectiveFrameCount().
const BLE_FRAME_CAP = 3;
const GPS_TIMEOUT_MS = 20000; // give up waiting for a one-shot fix after this
// Watchdog for the /frames request, in master ticks (FRAME_MS each). Over
// Bluetooth a request is proxied through the phone and a hung transfer can fail
// to invoke its callback at all. Without a guard that would hang "Loading
// radar..." forever. /frames is small JSON over makeWebRequest and returns
// quickly, so it only needs a short "dead link" guard. (The image requests have
// their own, much longer watchdog – see FramePipeline.mc.)
//
// NOTE: Connect IQ caps the number of concurrent Timer.Timer objects (~3), so a
// per-request watchdog timer is not viable. Instead one master timer (mTickTimer)
// drives playback, the busy animation, AND the watchdogs by counting ticks.
const FRAMES_TIMEOUT_TICKS = 30; // 30 * FRAME_MS = 15000 ms
// Two on-screen zoom presets. JMA radar + GSI base tiles exist across z4..11
// (verified against the origins). These two give a "wide area" vs "closer in"
// pair, clear of the z=11 edge (where some tiles 404 to blank). Tapping a
// button selects that level and re-fetches.
const ZOOM_WIDE  = 6;   // wide regional view
const ZOOM_LOCAL = 8;   // closer in (the default zoom)
// Connection kind, as inferred by connKind(). Enum-style consts rather than
// strings, so a typo in a comparison is a compile error instead of silently
// dropping every load onto the BLE frame cap.
const CONN_NONE  = 0;   // nothing connected
const CONN_PHONE = 1;   // Bluetooth via the phone
const CONN_WIFI  = 2;   // the Edge's fast direct path
// ----------------------------------------------------------------------------

class RadarView extends WatchUi.View {

    // The frame downloader (single-flight, retries, watchdog). This view is its
    // listener (onPipelineChanged) and drives its watchdog from onTick.
    hidden var mPipeline;
    hidden var mLabels as Lang.Array<Lang.String>?;       // JST "HH:MM" valid-time labels (proxy-provided, may be null)
    hidden var mOffsets as Lang.Array<Lang.Number>?;      // minutes from analysis time per frame (proxy-provided, may be null)
    hidden var mCurrent;       // frame index currently displayed
    // One master periodic timer drives playback, the busy animation, and the
    // transfer watchdogs. A single timer keeps us well under Connect IQ's
    // concurrent-Timer cap (mGpsTimer is the only other one, and it never
    // overlaps for long).
    hidden var mTickTimer;     // master periodic timer (FRAME_MS), null when stopped
    hidden var mGpsTimer;      // Timer guarding the GPS one-shot
    hidden var mAwaitingFrameList = false; // true while the /frames request is outstanding
    hidden var mAwaitTicks = 0; // ticks the in-flight /frames request has been waiting (watchdog)
    hidden var mBusyTick = 0;   // advances each tick, and drives the pulse/dots animation
    hidden var mStatus;        // user-facing status string
    hidden var mFailed;        // true once a step has failed (GPS / frame list / images), and gates the Retry button
    hidden var mSettingsError; // true on a settings problem a reload can't fix (no proxy URL / bad key)
    hidden var mLat;
    hidden var mLon;
    hidden var mHavePos;

    // Settings, read from app properties.
    hidden var mProxyBase;
    hidden var mProxyKey;
    hidden var mZoom;
    hidden var mFrameCount;

    // Cached screen size (from onLayout). Used to lay out the zoom buttons so the
    // renderer and the tap hit-test agree on their position.
    hidden var mW = 0;
    hidden var mH = 0;

    // Loop-view lifecycle. This RadarView is the widget-carousel (loop) view. It
    // also backs the pushed detail view, which shares this instance for state and
    // rendering (see enterDetail / RadarDetailView). mActive tracks whether a
    // load is running, so returning from the detail view resumes rather than
    // reloads. mPushingDetail suppresses the battery-saving suspend in onHide when
    // that onHide is only our own detail view covering the loop view.
    hidden var mActive = false;
    hidden var mPushingDetail = false;

    function initialize() {
        View.initialize();
        // FrameStore persists decoded frames to Application.Storage so they
        // survive a cold start (scrolling away in the carousel stops the widget).
        mPipeline = new FramePipeline(self, new CommsImageFetcher(), new FrameStore());
        readSettings();
        resetState();
    }

    function onLayout(dc) {
        mW = dc.getWidth();
        mH = dc.getHeight();
    }

    // ---- Settings ----------------------------------------------------------
    function readSettings() {
        // Every key has a default in resources/shared/properties.xml, so getValue never
        // returns null here – read directly (no nullable-fallback helper needed).
        mProxyBase  = Util.stripSlash(Application.Properties.getValue("proxyBase").toString());
        mProxyKey   = Application.Properties.getValue("proxyKey").toString();
        mZoom       = Util.clampNum(Application.Properties.getValue("zoom").toNumber(), 4, 11); // JMA/GSI tiles exist z4..11, and 12+ is blank
        mFrameCount = Util.clampNum(Application.Properties.getValue("frameCount").toNumber(), 1, 6); // 6 = device memory ceiling (a 7th frame OOMs)
    }

    // ---- Connection -------------------------------------------------------
    // "Loading radar..." tagged with how the data is coming in – Wi-Fi (the
    // Edge's fast direct path) or the phone (Bluetooth, ~30x slower for the image
    // tiles, which route through Garmin's image service). Helps explain why a BLE
    // load crawls while Wi-Fi is quick.
    function loadingText() {
        var kind = connKind();
        if (kind == CONN_WIFI)  { return "Loading radar (Wi-Fi)..."; }
        if (kind == CONN_PHONE) { return "Loading radar (phone)..."; }
        return "Loading radar...";
    }

    // Best-effort CONN_WIFI / CONN_PHONE / CONN_NONE.
    // DeviceSettings.connectionInfo maps each channel to a ConnectionInfo.state,
    // but the dictionary keys are opaque symbols we can't name (they stringify to
    // a hash), so we can't ask for the Wi-Fi channel directly. The Edge's only
    // data channels are the phone (BLE) and Wi-Fi, so we infer: a CONNECTED
    // channel BEYOND the phone is Wi-Fi. Otherwise, if the phone is connected,
    // we're loading over Bluetooth. (Assumes the phone is a single BLE channel,
    // which holds on current Edge firmware.)
    function connKind() {
        var ds = System.getDeviceSettings();
        var phone = (ds has :phoneConnected) ? ds.phoneConnected : false;
        var connected = 0;
        if (ds has :connectionInfo && ds.connectionInfo != null) {
            var ci = ds.connectionInfo;
            var keys = ci.keys();
            for (var i = 0; i < keys.size(); i += 1) {
                if (ci[keys[i]].state == System.CONNECTION_STATE_CONNECTED) { connected += 1; }
            }
        }
        if (connected > (phone ? 1 : 0)) { return CONN_WIFI; }  // a non-phone channel is up
        if (phone) { return CONN_PHONE; }
        return CONN_NONE;
    }

    // Frames to request for the current connection. frameCount is the Wi-Fi
    // maximum (image pulls are fast there). Over Bluetooth – or when we can't
    // tell – throttle to BLE_FRAME_CAP so the much slower image path still
    // produces a usable animation in reasonable time.
    function effectiveFrameCount() {
        return Util.frameCountFor(mFrameCount, connKind() == CONN_WIFI, BLE_FRAME_CAP);
    }

    // Called by the app when the user edits settings in Garmin Connect.
    function onSettingsChanged() {
        readSettings();
        reload();
    }

    // ---- Lifecycle ---------------------------------------------------------
    // Shown in the widget carousel, or re-shown when the detail view is popped.
    // A fresh appearance (scrolled to in the carousel) starts a load. A return
    // from the detail view must NOT reload – the load kept running underneath
    // it – so gate on mActive and only reload when we weren't already active.
    function onShow() {
        mPushingDetail = false;   // clear the guard if we just returned from detail
        if (mActive) { return; }  // returned from the detail view: keep the running load
        mActive = true;
        reload();
    }

    // Leaving the view: release GPS and stop both timers so nothing keeps
    // running (and draining battery) while the widget is off-screen. But when
    // the "hide" is only our own detail view being pushed on top, keep the load
    // running (mPushingDetail) so entering the detail view is seamless.
    function onHide() {
        if (mPushingDetail) { mPushingDetail = false; return; }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        stopTickTimer();
        stopGpsTimer();
        mActive = false;
    }

    // Enter the interactive detail view. On an Edge widget the carousel (loop)
    // view never receives coordinate-bearing taps – every tap arrives as the
    // coordinate-less SELECT – so we can't hit-test buttons here. A PUSHED view
    // does receive onTap with coordinates, so SELECT pushes RadarDetailView
    // (which shares this instance for state + rendering). There the Wide/Local/
    // Retry buttons become individually tappable and a press elsewhere does
    // nothing. mPushingDetail keeps onHide from tearing the load down.
    function enterDetail() {
        mPushingDetail = true;
        WatchUi.pushView(new RadarDetailView(self), new RadarDetailDelegate(self),
            WatchUi.SLIDE_IMMEDIATE);
    }

    // Reset the frame load: the fetch pipeline plus this view's per-load frame
    // metadata (labels/offsets/playback position). Shared by resetState (full
    // restart), setZoom (keeps the GPS fix) and onFrameList (which repopulates
    // right after).
    function resetLoad() {
        mPipeline.reset();
        mLabels = null;
        mOffsets = null;
        mCurrent = 0;
    }

    // Clear ALL per-load state back to a fresh "acquiring" state: the frame
    // load plus the GPS/status/failure fields the narrower resets leave alone.
    function resetState() {
        resetLoad();
        mAwaitingFrameList = false;
        mAwaitTicks = 0;
        mHavePos = false;
        mFailed = false;
        mSettingsError = false;
        mStatus = "Acquiring GPS...";
    }

    // Full restart: stop everything, clear state, re-acquire position.
    function reload() {
        stopTickTimer();
        stopGpsTimer();
        resetState();
        if (mProxyBase.length() == 0) {
            mSettingsError = true;   // nothing to retry until a URL is set
            mStatus = "Set Proxy URL in settings";
            WatchUi.requestUpdate();
            return;
        }
        startPositioning();
        WatchUi.requestUpdate();
    }

    // Apply a zoom level: persist it (so it stays in sync with the Garmin
    // Connect "zoom" setting) and re-fetch frames at the new zoom. We keep the
    // current GPS fix and only reset the frame load, so there's no GPS
    // re-acquire round-trip. If we don't have a fix yet, fall back to a full
    // reload.
    function setZoom(z) {
        if (z == mZoom) { return; }
        mZoom = z;
        Application.Properties.setValue("zoom", mZoom);
        stopTickTimer();
        if (mHavePos && mProxyBase.length() > 0) {
            resetLoad();   // keep the GPS fix, and just re-fetch at the new zoom
            mStatus = loadingText();
            requestFrameList();
            WatchUi.requestUpdate();
        } else {
            reload();
        }
    }

    // ---- Positioning -------------------------------------------------------
    function startPositioning() {
        // Fast path: a recent last-known fix lets us start loading immediately
        // instead of waiting for a fresh one-shot. City-zoom radar doesn't need
        // metre accuracy, so last-known is plenty to centre the view.
        var info = Position.getInfo();
        if (info.position != null
                && info.accuracy != Position.QUALITY_NOT_AVAILABLE) {
            usePosition(info);
        }
        // Still request a fresh one-shot to refine, and guard it with a timeout.
        Position.enableLocationEvents(Position.LOCATION_ONE_SHOT, method(:onPosition));
        mGpsTimer = new Timer.Timer();
        mGpsTimer.start(method(:onGpsTimeout), GPS_TIMEOUT_MS, false);
    }

    // GPS one-shot callback: record the fix (usePosition kicks off the frame
    // list on the first good one). Otherwise surface "No GPS fix" if we still
    // have nothing.
    function onPosition(info as Position.Info) as Void {
        if (info.position != null) {
            // If we already fast-started from last-known, usePosition won't
            // reload – the refined fix won't move a city-zoom tile.
            usePosition(info);
        } else if (!mHavePos) {
            mStatus = "No GPS fix";
            mFailed = true;
        }
        WatchUi.requestUpdate();
    }

    function usePosition(info) {
        var deg = info.position.toDegrees() as Lang.Array<Lang.Double>; // [lat, lon]
        mLat = deg[0];
        mLon = deg[1];
        mHavePos = true;
        stopGpsTimer();
        // First usable fix: start loading. The mAwaitingFrameList guard keeps a
        // refined fix arriving moments later from firing a duplicate /frames
        // request while the first is still in flight.
        if (!mPipeline.hasFrames() && !mAwaitingFrameList) {
            mStatus = loadingText();
            requestFrameList();
        }
    }

    function onGpsTimeout() as Void {
        mGpsTimer = null;
        if (!mHavePos && !mPipeline.hasFrames()) {
            mStatus = "No GPS fix";
            mFailed = true;
            WatchUi.requestUpdate();
        }
    }

    function stopGpsTimer() {
        if (mGpsTimer != null) {
            mGpsTimer.stop();
            mGpsTimer = null;
        }
    }

    // ---- Master tick timer -------------------------------------------------
    // One periodic timer covers playback animation, the busy-transfer animation,
    // and the transfer watchdogs. Started when loading begins (the first /frames
    // request) and kept alive while there's anything to animate (a transfer in
    // flight, or loaded frames to play). Stops itself otherwise to save battery.
    function startTickTimer() {
        if (mTickTimer != null) { return; }   // already running, so keep its phase
        mTickTimer = new Timer.Timer();
        mTickTimer.start(method(:onTick), FRAME_MS, true);
    }

    function stopTickTimer() {
        if (mTickTimer != null) {
            mTickTimer.stop();
            mTickTimer = null;
        }
    }

    // A transfer is in flight (frame list or an image) -> the indicator animates
    // and a watchdog counts against it.
    function isBusy() {
        return mAwaitingFrameList || mPipeline.isAwaiting();
    }

    // Watchdog: the /frames request hasn't called back in time. Surface a
    // transport failure so the Retry button appears instead of an indefinite
    // "Loading radar..." hang.
    function frameListTimedOut() {
        if (!mAwaitingFrameList) { return; }
        mAwaitingFrameList = false;
        mStatus = Util.httpErrorMsg(0); // "No phone connection"
        mFailed = true;
    }

    // ---- Step 1: get the ordered frame URL list from the proxy -------------
    function requestFrameList() {
        var url = mProxyBase + "/frames";
        var params = {
            "lat" => mLat,
            "lon" => mLon,
            "z"   => mZoom,
            "n"   => effectiveFrameCount(),
            "key" => mProxyKey
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        // Arm the BLE watchdog before firing: if the callback never returns
        // (hung phone link), the tick timer's count surfaces a retryable failure.
        mAwaitingFrameList = true;
        mAwaitTicks = 0;
        startTickTimer();
        Communications.makeWebRequest(url, params, options, method(:onFrameList));
    }

    // Callback for the /frames request: validate the response, capture the
    // labels/offsets, then hand the URL list to the pipeline (step 2), which
    // fetches the images one at a time (see FramePipeline).
    function onFrameList(code as Lang.Number, data as Lang.Dictionary or Lang.String or PersistedContent.Iterator or Null) as Void {
        // Ignore a stale/late response: the watchdog may already have given this
        // request up, or a reload superseded it.
        if (!mAwaitingFrameList) { return; }
        mAwaitingFrameList = false;
        if (code != 200 || data == null || !(data has :get)) {
            // 200 but unusable body (malformed JSON) vs an HTTP/transport error.
            mStatus = (code == 200) ? "Bad server response" : Util.httpErrorMsg(code);
            mFailed = true;
            if (code == 401) { mSettingsError = true; }  // bad key -> fix in settings
            WatchUi.requestUpdate();
            return;
        }
        var frames = data.get("frames") as Lang.Array<Lang.String>?;
        if (frames == null || frames.size() == 0) {
            mStatus = "No frames available";
            mFailed = true;
            WatchUi.requestUpdate();
            return;
        }

        resetLoad();
        mLabels = data.get("labels") as Lang.Array<Lang.String>?; // optional, null on older proxy
        mOffsets = data.get("offsets") as Lang.Array<Lang.Number>?; // optional, null on older proxy
        mPipeline.start(frames, mProxyBase, mProxyKey);
    }

    // FramePipeline listener: called after every image completion (success,
    // retry-queued failure, watchdog timeout, or a salvaged late arrival).
    // Keep the timer alive while transfers continue – or restart it when a
    // salvage lands after the pipeline already went idle, so playback runs –
    // surface a terminal failure when nothing loaded at all, and repaint.
    function onPipelineChanged() as Void {
        if (mPipeline.isAwaiting() || isLoaded()) { startTickTimer(); }

        // All requests done (none in flight, none queued or pending retry) and
        // nothing loaded => surface a failure instead of hanging on "Loading".
        // Prefer the specific reason (rate-limited, server error, no connection).
        if (mPipeline.done() && mPipeline.loadedCount() == 0) {
            // Every frame failed, so lastCode holds the last failure's code;
            // 0 here means a watchdog timeout, not "no failure recorded".
            var code = mPipeline.lastCode();
            if (code <= 0) {
                // Transport-level failure. While the phone is connected this is
                // the slow/flaky Garmin image service over BLE, not a dead link –
                // don't mislabel it "No phone connection". Wi-Fi is the direct path.
                mStatus = System.getDeviceSettings().phoneConnected
                    ? "Timed out: try Wi-Fi"
                    : Util.httpErrorMsg(0);   // "No phone connection"
            } else {
                mStatus = Util.httpErrorMsg(code);
            }
            mFailed = true;
            if (code == 401) { mSettingsError = true; }  // bad key -> fix in settings
        }
        WatchUi.requestUpdate();
    }

    // ---- Master tick: animation + watchdog ---------------------------------
    // Fires every FRAME_MS while loading or playing. Three jobs: (1) advance the
    // busy-indicator phase, (2) charge the transfer watchdogs (the pipeline
    // handles its own, and the /frames one is counted here), (3) advance playback
    // across loaded frames. Self-stops once there's nothing left to animate or
    // play.
    function onTick() as Void {
        mBusyTick += 1;

        // (2) Watchdogs. frameListTimedOut clears the awaiting flag, so it
        // fires at most once per stuck request. The pipeline's tick() does the
        // same for the in-flight image.
        if (mAwaitingFrameList) {
            mAwaitTicks += 1;
            if (mAwaitTicks >= FRAMES_TIMEOUT_TICKS) {
                mAwaitTicks = 0;
                frameListTimedOut();
            }
        }
        mPipeline.tick();

        // (3) Advance playback across the frames loaded so far. Frames stream in
        // oldest->newest. If we looped the whole set while still loading, playback
        // would wrap from the newest-loaded frame back to -15m every lap, so the
        // time appears to jump around. Instead, while loading, only ever move
        // *forwards* to the next loaded frame and hold on the leading edge until a
        // newer one arrives – the time climbs monotonically. We resume normal
        // wrap-around looping once loading is done (all requests attempted), so a
        // failed/missing frame can't freeze playback at a permanent gap.
        if (mPipeline.hasFrames()) {
            var n = mPipeline.size();
            var loadingDone = mPipeline.done();

            var next = -1;
            for (var i = mCurrent + 1; i < n; i += 1) {
                if (mPipeline.isFrameLoaded(i)) { next = i; break; }
            }

            if (next != -1) {
                mCurrent = next;
            } else if (loadingDone) {
                // Wrap to the first loaded frame to loop the full set.
                for (var i = 0; i < n; i += 1) {
                    if (mPipeline.isFrameLoaded(i)) { mCurrent = i; break; }
                }
            }
            // else: still loading with nothing newer ready -> hold on the edge.
        }

        WatchUi.requestUpdate();

        // Nothing left to animate (no transfer in flight) and nothing to play
        // (no loaded frame) -> stop the timer to save battery. Playback keeps it
        // alive via isLoaded(). A terminal failure with no frames lets it stop.
        if (!isBusy() && !isLoaded()) { stopTickTimer(); }
    }

    // ---- Render ------------------------------------------------------------
    // The loop view renders itself. The pushed detail view renders this same
    // instance by calling draw(dc) directly, so both show identical radar.
    function onUpdate(dc) {
        draw(dc);
    }

    function draw(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var bmp = mPipeline.frameAt(mCurrent);
        if (bmp != null) {
            drawRadarScreen(dc, bmp);
        } else {
            drawLoadingScreen(dc);
        }

        // Bottom control, drawn last so it sits on top: the Wide/Local zoom
        // selector once a frame has loaded (both shown, the current level
        // highlighted), or a Retry button once a step has failed. While still
        // acquiring GPS / loading, neither shows.
        if (isLoaded()) {
            drawZoomButtons(dc);
        } else if (canRetry()) {
            drawBottomButton(dc, "Retry");
        }
    }

    // Radar branch of the render: the current frame with its title row, the
    // rider marker, the per-frame progress bar while frames are still arriving,
    // and the attribution line.
    function drawRadarScreen(dc, bmp) {
        var w = dc.getWidth();
        var fhTiny = dc.getFontHeight(Graphics.FONT_XTINY);
        var bx = (w - bmp.getWidth()) / 2;

        // Distribute the screen evenly rather than centring the image (which
        // left the top sparse and the bottom crowded). Three equal gaps:
        // top labels -> image, image -> attribution, attribution -> buttons.
        // This nudges the radar image up from dead-centre.
        var topEnd = 4 + fhTiny;               // bottom of the frame-index / time row
        var btnTop = bottomButtonRect()[1];    // top edge of the bottom buttons (shared edge)
        var gap = (btnTop - topEnd - bmp.getHeight() - fhTiny) / 3;
        if (gap < 0) { gap = 0; }
        var by = topEnd + gap;
        dc.drawBitmap(bx, by, bmp);

        // Rider marker at the image centre (the proxy may also bake one in,
        // so this
        // is a UI fallback).
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(w / 2, by + bmp.getHeight() / 2, 3);

        // Playback starts at 2 frames, so the rest keep downloading in the
        // background. Keep a thin segmented bar pinned to the top edge until
        // every frame has arrived: one cell per frame, the in-flight cell
        // pulsing, so the user can see each remaining transfer continue.
        if (mPipeline.loadedCount() < mPipeline.size()) {
            drawSegmentedBar(dc, 0, 0, w, 3, mPipeline.size(), mPipeline.inflightIndex());
        }

        // Centred title row: the frame index plus the frame's own JST valid
        // time and its fixed offset from the analysis time, for example
        // "2/3  22:40 +15m" (forecast) or "2/3  22:25 now" (latest observed).
        // The time/offset come from the proxy, so they're stable and
        // independent of the device clock / timezone.
        var title = (mCurrent + 1) + "/" + mPipeline.size();
        var label = currentLabel();
        if (label != null) {
            title = title + "   " + label;
            var off = currentOffset();
            if (off != null) {
                title = title + " " + Util.offsetStr(off);
            }
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 4, Graphics.FONT_XTINY, title,
            Graphics.TEXT_JUSTIFY_CENTER);

        // Mandatory attribution, one line, centred below the radar image.
        // Romanized because the device system font carries no CJK glyphs when
        // the device language is not Japanese. Both required elements are
        // kept: JMA's "processed" notice (加工して利用, because we composite and
        // crop the
        // tiles) and the GSI base-map credit. Sits in the gap between the
        // bottom of the image and the top of the zoom buttons.
        var imgBottom = by + bmp.getHeight();
        var attrY = (imgBottom + btnTop) / 2;
        dc.drawText(w / 2, attrY, Graphics.FONT_XTINY,
            "JMA Weather (processed) · GSI Map",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Loading/status branch of the render: status line, optional download
    // progress (or activity dots), and the load-time disclaimer – measured and
    // drawn as one block that is vertically centred on the screen.
    function drawLoadingScreen(dc) {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var fhSmall = dc.getFontHeight(Graphics.FONT_SMALL);
        var fhTiny = dc.getFontHeight(Graphics.FONT_XTINY);
        var hasProg = mPipeline.size() > 0;
        // Before the frame list arrives there's no per-frame progress to show,
        // so a transfer in flight (the /frames fetch) gets animated dots.
        var showDots = !hasProg && isBusy();
        var dotsH = 5;
        var gap = 6;
        var headGap = 16;   // breathing room between the status line and the indicator below it

        var stackH = fhSmall;                                  // status
        if (hasProg) { stackH += headGap + fhTiny + gap + 6; } // count + bar
        else if (showDots) { stackH += headGap + dotsH; }      // activity dots
        stackH += gap * 4 + fhTiny + gap + fhTiny * 3;         // separation, 'Disclaimer' title, gap, 3 lines

        // Top of the centred stack. Each element is top-justified and y
        // advances by its height.
        var y = (h - stackH) / 2;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, y, Graphics.FONT_SMALL, mStatus,
            Graphics.TEXT_JUSTIFY_CENTER);
        y += fhSmall;

        // Once the frame list is known, show download progress under the
        // status: a "loaded / total" count plus a bar, so the wait while
        // the first frames stream over BLE isn't a blank "Loading..." screen.
        if (hasProg) {
            y += headGap;
            dc.drawText(w / 2, y, Graphics.FONT_XTINY,
                mPipeline.loadedCount() + " / " + mPipeline.size(),
                Graphics.TEXT_JUSTIFY_CENTER);
            y += fhTiny + gap;
            var barW = w / 2;
            drawSegmentedBar(dc, (w - barW) / 2, y, barW, 6,
                mPipeline.size(), mPipeline.inflightIndex());
            y += 6;
        } else if (showDots) {
            y += headGap;
            drawActivityDots(dc, w / 2, y + dotsH / 2);
            y += dotsH;
        }

        // Load-time disclaimer: this is informational radar, not a safety
        // tool. Hardcoded + romanised (like the credit line) since device
        // fonts lack CJK glyphs. Set apart from the status/progress above by
        // a wider gap and a "Disclaimer" heading. Clears once the first frame
        // draws and the view switches to the radar branch.
        y += gap * 4;   // wider separation from the loading messages
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, y, Graphics.FONT_XTINY,
            "Disclaimer", Graphics.TEXT_JUSTIFY_CENTER);
        y += fhTiny + gap;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, y, Graphics.FONT_XTINY,
            "For information only.", Graphics.TEXT_JUSTIFY_CENTER);
        y += fhTiny;
        dc.drawText(w / 2, y, Graphics.FONT_XTINY,
            "Data may be delayed or", Graphics.TEXT_JUSTIFY_CENTER);
        y += fhTiny;
        dc.drawText(w / 2, y, Graphics.FONT_XTINY,
            "unavailable. Not for safety.", Graphics.TEXT_JUSTIFY_CENTER);
    }

    // True once at least one radar frame has loaded – that is, a successful load.
    // The zoom toggle is gated on this. Before it, the bottom shows Retry.
    function isLoaded() {
        return mPipeline.loadedCount() > 0;
    }

    // Whether a Retry makes sense: a step has actually failed (so we're not just
    // mid-load), and the problem isn't a settings issue a reload can't fix (no
    // proxy URL, or a bad key). Those are corrected in app settings, which
    // reloads automatically (onSettingsChanged). While still acquiring GPS or
    // loading frames, mFailed is false, so no Retry button shows.
    function canRetry() {
        return mFailed && !isLoaded() && !mSettingsError;
    }

    // ---- Bottom buttons ----------------------------------------------------
    // The bottom edge holds one of two controls: the Wide/Local zoom selector
    // (both shown, current highlighted) once radar is showing, or a single
    // Retry button after a failure. All share this bottom edge.
    //
    // Interaction note: the carousel (loop) view never gets coordinate-bearing
    // taps, but the pushed detail view does (see enterDetail / RadarDetailView).
    // These rects are the shared geometry the detail view's onTap hit-tests
    // (onScreenTap), so a tap switches straight to the tapped level and a press
    // off both buttons does nothing.

    // One centred button (Retry), pinned to the bottom edge.
    function bottomButtonRect() as Lang.Array<Lang.Number> {
        var bw = (mW * 6) / 10;          // ~60% of the width, centred
        var bh = 30;
        var bx = (mW - bw) / 2;
        var by = mH - bh - 8;            // pinned to the bottom edge of the screen
        return [bx, by, bw, bh];
    }

    function drawBottomButton(dc, label) {
        if (mW <= 0) { return; }
        var r = bottomButtonRect();
        var x = r[0]; var y = r[1]; var bw = r[2]; var bh = r[3];
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, y, bw, bh, 4);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + bw / 2, y + bh / 2, Graphics.FONT_XTINY, label,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // The two zoom-selector buttons [left=Wide, right=Local], same bottom edge
    // as the Retry button. Geometry is shared by the renderer and the tap
    // hit-test (onScreenTap) so they can't drift.
    function zoomButtonRects() as Lang.Array<Lang.Array<Lang.Number>> {
        var bw = (mW * 4) / 10;          // each button ~40% of the width
        var bh = 30;
        var gap = mW / 20;
        var bx = (mW - (bw * 2 + gap)) / 2;
        var by = mH - bh - 8;            // same bottom edge as bottomButtonRect
        return [
            [bx, by, bw, bh],                 // left  -> Wide
            [bx + bw + gap, by, bw, bh]       // right -> Local
        ];
    }

    function drawZoomButtons(dc) {
        if (mW <= 0) { return; }
        var r = zoomButtonRects();
        drawZoomButton(dc, r[0], "Wide", mZoom == ZOOM_WIDE);
        drawZoomButton(dc, r[1], "Local", mZoom == ZOOM_LOCAL);
    }

    // A selected button is filled blue with white text (the current level). An
    // unselected one is a grey outline with grey text (the level a tap switches
    // to).
    function drawZoomButton(dc, r as Lang.Array<Lang.Number>, label, selected) {
        var x = r[0]; var y = r[1]; var bw = r[2]; var bh = r[3];
        if (selected) {
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x, y, bw, bh, 4);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(x, y, bw, bh, 4);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        }
        dc.drawText(x + bw / 2, y + bh / 2, Graphics.FONT_XTINY, label,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Touch dispatch from the detail view's delegate (onTap, with coordinates).
    // The carousel loop view never gets coordinates, but the pushed detail view
    // does, so this is where per-button taps land: a tap switches straight to
    // the tapped zoom level (tapping the current level, or missing both, does
    // nothing), or triggers Retry after a failure.
    function onScreenTap(x, y) {
        if (mW <= 0) { return false; }
        // Before a successful load the only control is the Retry button (and
        // only when a retry could help).
        if (!isLoaded()) {
            if (canRetry() && hitTest(bottomButtonRect(), x, y)) { reload(); return true; }
            return false;
        }
        var r = zoomButtonRects();
        if (hitTest(r[0], x, y)) { setZoom(ZOOM_WIDE); return true; }   // no-op if already Wide
        if (hitTest(r[1], x, y)) { setZoom(ZOOM_LOCAL); return true; }  // no-op if already Local
        return false;
    }

    function hitTest(r as Lang.Array<Lang.Number>, x, y) {
        return x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3];
    }

    // Draw a per-frame progress bar: one cell per frame so each transfer is
    // visible individually. A loaded cell is solid white (done). A permanently
    // failed cell (out of retries / non-retryable) is solid red – it can still
    // turn white later if an abandoned transfer's late arrival is salvaged. The
    // in-flight cell (activeIdx) pulses between two greys so the active
    // transfer reads as "working". A not-yet-started cell is a dim outline.
    // Used both on the loading screen and as a slim top-edge indicator during
    // playback.
    function drawSegmentedBar(dc, x, y, w, h, n, activeIdx) {
        if (n <= 0) { return; }
        var sgap = (n > 1) ? 2 : 0;
        var cellW = (w - sgap * (n - 1)) / n;
        if (cellW < 1) { cellW = 1; }
        var blinkOn = (mBusyTick % 2) == 0;
        var cx = x;
        for (var i = 0; i < n; i += 1) {
            if (mPipeline.isFrameLoaded(i)) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(cx, y, cellW, h);
            } else if (mPipeline.isFrameFailed(i)) {
                dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(cx, y, cellW, h);
            } else if (i == activeIdx) {
                dc.setColor(blinkOn ? Graphics.COLOR_LT_GRAY : Graphics.COLOR_DK_GRAY,
                    Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(cx, y, cellW, h);
            } else {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawRectangle(cx, y, cellW, h);
            }
            cx += cellW + sgap;
        }
    }

    // Indeterminate "working" indicator: three dots with the highlight cycling
    // across them. Shown while a transfer is in flight but there's no per-frame
    // progress yet (the /frames request, before the frame count is known).
    function drawActivityDots(dc, cx, cy) {
        var dots = 3;
        var r = 2;
        var spacing = 8;
        var startX = cx - ((dots - 1) * spacing) / 2;
        var active = mBusyTick % dots;
        for (var i = 0; i < dots; i += 1) {
            dc.setColor((i == active) ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY,
                Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(startX + i * spacing, cy, r);
        }
    }

    // The proxy-provided label for the current frame, if available.
    function currentLabel() {
        if (mLabels != null && mCurrent < mLabels.size()) {
            return mLabels[mCurrent];
        }
        return null;
    }

    // The proxy-provided offset (minutes from analysis time) for the current
    // frame, if available. null on older proxies that don't send offsets.
    function currentOffset() {
        if (mOffsets != null && mCurrent < mOffsets.size()) {
            return mOffsets[mCurrent];
        }
        return null;
    }

}

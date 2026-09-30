using Toybox.WatchUi;
using Toybox.Position;
using Toybox.Timer;
using Toybox.Application;
using Toybox.Lang;
using Toybox.System;

// ---- CONFIG ----------------------------------------------------------------
// User-facing config (proxy URL, key, zoom, frame count) lives in app settings
// (resources/shared/settings.xml -> properties.xml), editable from Garmin Connect with
// no rebuild. Only the fixed playback tuning stays as consts here. The image
// pipeline's tuning (retries, transfer watchdog, tile size) lives with the
// pipeline in FramePipeline.mc, and the /frames watchdog in FrameListClient.mc.
const FRAME_MS = 500;       // ms per frame during playback, and the master tick interval
// Over Bluetooth each tile is ~30x slower (Garmin's image service), so cap the
// number of frames fetched to keep the animation usable. On Wi-Fi (the fast
// direct path) we load the full frameCount setting. See effectiveFrameCount().
const BLE_FRAME_CAP = 3;
const GPS_TIMEOUT_MS = 20000; // give up waiting for a one-shot fix after this
// Fetch a fresh frame list this long after a load completes, while the widget
// stays open. JMA publishes every 5 minutes, but over Bluetooth a load costs
// ~30 s of transfers per frame, so every 10 minutes balances fresh radar
// against battery.
const REFRESH_MS = 10 * 60 * 1000;
//
// NOTE: Connect IQ caps the number of concurrent Timer.Timer objects (~3), so a
// per-request watchdog timer is not viable. One master timer (mTickTimer)
// drives playback, the busy animation AND the watchdogs by counting ticks. The
// GPS timer only runs before the first fix, and the refresh timer only after a
// load, so at most three are ever alive.
//
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

// The radar widget's state and control flow: settings, lifecycle, GPS, and the
// two steps of a load (FrameListClient fetches the frame list, FramePipeline
// the images), plus playback. RadarRenderer draws it.
class RadarView extends WatchUi.View {

    hidden var mFrameList;     // FrameListClient: the /frames request (step 1)
    hidden var mPipeline;      // FramePipeline: the frame images (step 2)
    hidden var mRenderer;      // RadarRenderer: drawing + button geometry
    hidden var mLabels as Lang.Array<Lang.String>?;       // JST "HH:MM" valid-time labels (proxy-provided, may be null)
    hidden var mOffsets as Lang.Array<Lang.Number>?;      // minutes from analysis time per frame (proxy-provided, may be null)
    hidden var mCurrent;       // frame index currently displayed
    // The frame on screen when a refresh started. Drawn until the first new
    // frame arrives, so a refresh doesn't blank the radar for a whole BLE load.
    // Only one extra bitmap, and only until that first frame lands, so it stays
    // well inside the 6-frame memory ceiling.
    hidden var mHold;
    hidden var mTickTimer;     // master periodic timer (FRAME_MS), null when stopped
    hidden var mGpsTimer;      // Timer guarding the GPS one-shot
    hidden var mRefreshTimer;  // one-shot Timer for the next frame-list refresh
    hidden var mBusyTick = 0;  // advances each tick, and drives the pulse/dots animation
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
        mFrameList = new FrameListClient(self, new CommsWebFetcher());
        // FrameStore persists decoded frames to Application.Storage so they
        // survive a cold start (scrolling away in the carousel stops the widget).
        mPipeline = new FramePipeline(self, new CommsImageFetcher(), new FrameStore());
        mRenderer = new RadarRenderer(self);
        readSettings();
        resetState();
    }

    function onLayout(dc) {
        mRenderer.onLayout(dc);
    }

    // ---- State the renderer reads ------------------------------------------
    function pipeline() { return mPipeline; }
    function current() { return mCurrent; }
    function holdBitmap() { return mHold; }
    function status() { return mStatus; }
    function zoom() { return mZoom; }
    function busyTick() { return mBusyTick; }

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

    // Called by the app when the user edits settings in Garmin Connect. Only
    // reload while on screen: a hidden widget must not start GPS and network
    // requests. The next onShow reloads with the new settings anyway.
    function onSettingsChanged() {
        readSettings();
        if (mActive) { reload(); }
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

    // Leaving the view: release GPS, stop every timer and drop the load in
    // flight, so nothing keeps running (and draining battery) while the widget
    // is off-screen. Stopping the timers alone was not enough: the next image
    // callback would pump the next request and restart the tick timer. The
    // frame cache keeps the bitmaps, so the next onShow is still instant. But
    // when the "hide" is only our own detail view being pushed on top, keep the
    // load running (mPushingDetail) so entering the detail view is seamless.
    function onHide() {
        if (mPushingDetail) { mPushingDetail = false; return; }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        stopTimers();
        mFrameList.cancel();
        resetLoad();
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
    // restart), setZoom (keeps the GPS fix), refresh and onFrameList (which
    // repopulates right after).
    function resetLoad() {
        mPipeline.reset();
        mLabels = null;
        mOffsets = null;
        mCurrent = 0;
        mHold = null;
    }

    // Clear ALL per-load state back to a fresh "acquiring" state: the frame
    // load plus the GPS/status/failure fields the narrower resets leave alone.
    function resetState() {
        mFrameList.cancel();
        resetLoad();
        mHavePos = false;
        mFailed = false;
        mSettingsError = false;
        mStatus = "Acquiring GPS...";
    }

    // Full restart: stop everything, clear state, re-acquire position.
    function reload() {
        stopTimers();
        resetState();
        var bad = Util.settingsError(mProxyBase, mProxyKey);
        if (bad != null) {
            mSettingsError = true;   // nothing to retry until the settings change
            mStatus = bad;
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
        stopRefreshTimer();
        if (mHavePos && Util.settingsError(mProxyBase, mProxyKey) == null) {
            resetLoad();   // keep the GPS fix, and just re-fetch at the new zoom
            mFailed = false;
            mStatus = loadingText();
            requestFrameList();
            WatchUi.requestUpdate();
        } else {
            reload();
        }
    }

    // Show a failure. A 401 is a settings problem, so no Retry button: fixing
    // the key in the settings reloads on its own (onSettingsChanged).
    function fail(msg as Lang.String, code as Lang.Number) as Void {
        mStatus = msg;
        mFailed = true;
        if (code == 401) { mSettingsError = true; }
        WatchUi.requestUpdate();
    }

    // ---- Positioning -------------------------------------------------------
    function startPositioning() {
        // Fast path: a recent last-known fix lets us start loading immediately
        // instead of waiting for a fresh one-shot. City-zoom radar doesn't need
        // metre accuracy, so last-known is plenty to centre the view.
        var info = Position.getInfo();
        if (hasFix(info)) {
            usePosition(info);
        }
        // Still request a fresh one-shot to refine, and guard it with a timeout
        // when there is no fix yet. With a fix the load has already started,
        // so there is nothing to time out.
        Position.enableLocationEvents(Position.LOCATION_ONE_SHOT, method(:onPosition));
        if (!mHavePos) {
            mGpsTimer = new Timer.Timer();
            mGpsTimer.start(method(:onGpsTimeout), GPS_TIMEOUT_MS, false);
        }
    }

    function hasFix(info as Position.Info) as Lang.Boolean {
        return info.position != null && info.accuracy != Position.QUALITY_NOT_AVAILABLE;
    }

    // GPS one-shot callback: record the fix (usePosition kicks off the frame
    // list on the first good one). Otherwise surface "No GPS fix" if we still
    // have nothing.
    function onPosition(info as Position.Info) as Void {
        if (hasFix(info)) {
            // If we already fast-started from last-known, usePosition won't
            // reload – the refined fix won't move a city-zoom tile.
            usePosition(info);
        } else if (!mHavePos) {
            fail("No GPS fix", 0);
        }
        WatchUi.requestUpdate();
    }

    function usePosition(info as Position.Info) {
        var deg = info.position.toDegrees() as Lang.Array<Lang.Double>; // [lat, lon]
        mLat = deg[0];
        mLon = deg[1];
        mHavePos = true;
        stopGpsTimer();
        // First usable fix: start loading. The isAwaiting guard keeps a refined
        // fix arriving moments later from firing a duplicate /frames request
        // while the first is still in flight. A fix that arrives after the GPS
        // timeout clears the "No GPS fix" failure and loads as normal.
        if (!mPipeline.hasFrames() && !mFrameList.isAwaiting()) {
            mFailed = false;
            mStatus = loadingText();
            requestFrameList();
        }
    }

    // The one-shot request keeps searching after this, on purpose: a fix that
    // arrives later still starts the load (see usePosition).
    function onGpsTimeout() as Void {
        mGpsTimer = null;
        if (!mHavePos && !mPipeline.hasFrames()) {
            fail("No GPS fix", 0);
        }
    }

    // ---- Timers ------------------------------------------------------------
    // One periodic timer covers playback animation, the busy-transfer animation,
    // and the transfer watchdogs. Started when loading begins (the first /frames
    // request) and kept alive only while there's something to animate: a
    // transfer in flight, or more than one loaded frame to play. A single frame
    // never changes, so redrawing it twice a second would only drain the battery.
    function startTickTimer() {
        if (mTickTimer != null) { return; }   // already running, so keep its phase
        mTickTimer = new Timer.Timer();
        mTickTimer.start(method(:onTick), FRAME_MS, true);
    }

    function needsTick() as Lang.Boolean {
        return isBusy() || mPipeline.loadedCount() > 1;
    }

    function stopTickTimer() {
        if (mTickTimer != null) {
            mTickTimer.stop();
            mTickTimer = null;
        }
    }

    function stopGpsTimer() {
        if (mGpsTimer != null) {
            mGpsTimer.stop();
            mGpsTimer = null;
        }
    }

    function startRefreshTimer() {
        if (mRefreshTimer != null) { return; }
        mRefreshTimer = new Timer.Timer();
        mRefreshTimer.start(method(:onRefresh), REFRESH_MS, false);
    }

    function stopRefreshTimer() {
        if (mRefreshTimer != null) {
            mRefreshTimer.stop();
            mRefreshTimer = null;
        }
    }

    function stopTimers() {
        stopTickTimer();
        stopGpsTimer();
        stopRefreshTimer();
    }

    // A transfer is in flight -> the indicator animates and a watchdog counts
    // against it.
    function isBusy() {
        return mFrameList.isAwaiting() || mPipeline.isAwaiting();
    }

    // ---- Refresh -----------------------------------------------------------
    // The frame list is a snapshot: left open, the widget would keep playing
    // radar that is 45 minutes old. Fetch a new list from the latest known
    // position, and keep the current frame on screen until a new one arrives.
    function onRefresh() as Void {
        mRefreshTimer = null;
        if (!mActive) { return; }
        if (isBusy()) { startRefreshTimer(); return; }   // try again next period
        var info = Position.getInfo();
        if (hasFix(info)) {
            var deg = info.position.toDegrees() as Lang.Array<Lang.Double>;
            mLat = deg[0];
            mLon = deg[1];
        }
        var hold = mPipeline.frameAt(mCurrent);
        stopTickTimer();
        resetLoad();
        mHold = hold;
        mStatus = "Updating radar...";
        requestFrameList();
        WatchUi.requestUpdate();
    }

    // ---- Step 1: get the ordered frame URL list from the proxy -------------
    function requestFrameList() {
        mFrameList.request(mProxyBase, mProxyKey, mLat, mLon, mZoom, effectiveFrameCount());
        startTickTimer();   // drives the /frames watchdog
    }

    // FrameListClient listener: hand the URL list to the pipeline (step 2),
    // which fetches the images one at a time.
    function onFrameList(frames as Lang.Array<Lang.String>, labels, offsets) as Void {
        var hold = mHold;
        resetLoad();
        mHold = hold;   // keep showing it until the first new frame arrives
        mLabels = labels;
        mOffsets = offsets;
        mPipeline.start(frames, mProxyBase, mProxyKey);
    }

    function onFrameListFailed(code as Lang.Number, msg) as Void {
        if (mHold != null) {
            // A refresh failed: keep the old radar on screen and try again later.
            mStatus = "Update failed";
            startRefreshTimer();
            WatchUi.requestUpdate();
            return;
        }
        fail((msg != null) ? msg : frameListErrorMsg(code), code);
    }

    // The /frames watchdog reports code 0. That is a dead link only when nothing
    // is connected. With Wi-Fi or the phone up, it just timed out.
    hidden function frameListErrorMsg(code as Lang.Number) as Lang.String {
        if (code == 0 && connKind() != CONN_NONE) { return "Timed out"; }
        return Util.httpErrorMsg(code);
    }

    // FramePipeline listener: called after every image completion (success,
    // retry-queued failure, watchdog timeout, or a salvaged late arrival).
    // Keep the timer alive while there is something to animate, surface a
    // terminal failure when nothing loaded at all, and repaint.
    function onPipelineChanged() as Void {
        if (!mActive) { return; }   // hidden: the load was torn down in onHide
        if (isLoaded()) { mHold = null; }   // a new frame replaces the held one
        if (needsTick()) { startTickTimer(); }

        if (mPipeline.done()) {
            if (isLoaded()) {
                // Playback may not be ticking (a single frame), so make sure the
                // frame on screen is a loaded one, then schedule the refresh.
                mCurrent = Util.nextFrame(mCurrent - 1, loadedFlags(), true);
                startRefreshTimer();
            } else {
                // Every frame failed, so lastCode holds the last failure's code;
                // 0 here means a watchdog timeout, not "no failure recorded".
                var code = mPipeline.lastCode();
                var msg;
                if (code == 0) {
                    // Over BLE this is Garmin's slow or flaky image service, not
                    // a dead link, so point at the faster path.
                    var kind = connKind();
                    if (kind == CONN_PHONE) { msg = "Timed out: try Wi-Fi"; }
                    else if (kind == CONN_WIFI) { msg = "Timed out"; }
                    else { msg = Util.httpErrorMsg(0); }
                } else {
                    msg = Util.httpErrorMsg(code);
                }
                mHold = null;
                fail(msg, code);
            }
        }
        WatchUi.requestUpdate();
    }

    // ---- Master tick: animation + watchdogs + playback ---------------------
    // Fires every FRAME_MS while loading or playing. Three jobs: (1) advance the
    // busy-indicator phase, (2) charge the transfer watchdogs, (3) advance
    // playback across loaded frames. Stops itself once there's nothing left to
    // animate.
    function onTick() as Void {
        mBusyTick += 1;
        mFrameList.tick();
        mPipeline.tick();
        if (mPipeline.hasFrames()) {
            mCurrent = Util.nextFrame(mCurrent, loadedFlags(), mPipeline.done());
        }
        WatchUi.requestUpdate();
        if (!needsTick()) { stopTickTimer(); }
    }

    hidden function loadedFlags() as Lang.Array<Lang.Boolean> {
        var n = mPipeline.size();
        var flags = new [n];
        for (var i = 0; i < n; i += 1) { flags[i] = mPipeline.isFrameLoaded(i); }
        return flags;
    }

    // ---- Render ------------------------------------------------------------
    // The loop view renders itself. The pushed detail view renders this same
    // instance by calling draw(dc) directly, so both show identical radar.
    function onUpdate(dc) {
        draw(dc);
    }

    function draw(dc) {
        mRenderer.draw(dc);
    }

    // True once at least one radar frame has loaded – that is, a successful load.
    function isLoaded() {
        return mPipeline.loadedCount() > 0;
    }

    // Radar is on screen: a loaded frame, or the frame held during a refresh.
    // The zoom buttons show while this is true. Before it, the bottom shows Retry.
    function hasRadar() {
        return isLoaded() || mHold != null;
    }

    // Whether a Retry makes sense: a step has actually failed (so we're not just
    // mid-load), and the problem isn't a settings issue a reload can't fix (no
    // proxy URL, or a bad key). Those are corrected in app settings, which
    // reloads automatically (onSettingsChanged). While still acquiring GPS or
    // loading frames, mFailed is false, so no Retry button shows.
    function canRetry() {
        return mFailed && !hasRadar() && !mSettingsError;
    }

    // Touch dispatch from the detail view's delegate (onTap, with coordinates).
    // The carousel loop view never gets coordinates, but the pushed detail view
    // does, so this is where per-button taps land: a tap switches straight to
    // the tapped zoom level (tapping the current level, or missing both, does
    // nothing), or triggers Retry after a failure.
    function onScreenTap(x, y) {
        if (!mRenderer.hasLayout()) { return false; }
        // Before any radar shows, the only control is the Retry button (and
        // only when a retry could help).
        if (!hasRadar()) {
            if (canRetry() && hitTest(mRenderer.bottomButtonRect(), x, y)) { reload(); return true; }
            return false;
        }
        var r = mRenderer.zoomButtonRects() as Lang.Array<Lang.Array<Lang.Number>>;
        if (hitTest(r[0], x, y)) { setZoom(ZOOM_WIDE); return true; }   // no-op if already Wide
        if (hitTest(r[1], x, y)) { setZoom(ZOOM_LOCAL); return true; }  // no-op if already Local
        return false;
    }

    function hitTest(r as Lang.Array<Lang.Number>, x, y) {
        return x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3];
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

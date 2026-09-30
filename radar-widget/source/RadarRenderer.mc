using Toybox.Graphics;
using Toybox.Lang;

const BUTTON_H = 30;
const BUTTON_MARGIN = 8;   // gap between the bottom buttons and the screen edge

// Draws the radar widget and owns the on-screen button geometry, so the
// renderer and the tap hit-test (RadarView.onScreenTap) can't drift apart. It
// holds no load state: every value comes from the RadarView it renders.
class RadarRenderer {

    hidden var mView;

    // Cached screen size (from onLayout), for the button geometry.
    hidden var mW = 0;
    hidden var mH = 0;

    function initialize(view) {
        mView = view;
    }

    function onLayout(dc) {
        mW = dc.getWidth();
        mH = dc.getHeight();
    }

    function draw(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var p = mView.pipeline();
        var bmp = p.frameAt(mView.current());
        var holding = false;
        if (bmp == null) {
            // During a refresh, keep the last frame up until a new one arrives.
            bmp = mView.holdBitmap();
            holding = (bmp != null);
        }
        if (bmp != null) {
            drawRadarScreen(dc, bmp, holding);
        } else {
            drawLoadingScreen(dc);
        }

        // Bottom control, drawn last so it sits on top: the Wide/Local zoom
        // selector while radar is showing (both shown, the current level
        // highlighted), or a Retry button once a step has failed. While still
        // acquiring GPS / loading, neither shows.
        if (mView.hasRadar()) {
            drawZoomButtons(dc);
        } else if (mView.canRetry()) {
            drawBottomButton(dc, "Retry");
        }
    }

    // Radar branch of the render: the current frame with its title row, the
    // per-frame progress bar while frames are still arriving, and the
    // attribution line. The rider marker is part of the image (the proxy draws
    // it).
    hidden function drawRadarScreen(dc, bmp, holding) {
        var p = mView.pipeline();
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

        // Playback starts as soon as the first frame arrives, and the rest keep
        // downloading in the background. Keep a thin segmented bar pinned to the
        // top edge until every frame has arrived: one cell per frame, the
        // in-flight cell pulsing, so each remaining transfer is visible.
        if (p.size() > 0 && p.loadedCount() < p.size()) {
            drawSegmentedBar(dc, 0, 0, w, 3, p.size(), p.inflightIndex());
        }

        // Centred title row: the frame index plus the frame's own JST valid
        // time and its fixed offset from the analysis time, for example
        // "2/3  22:40 +15m" (forecast) or "2/3  22:25 now" (latest observed).
        // The time/offset come from the proxy, so they're stable and
        // independent of the device clock / timezone. While an old frame is
        // held during a refresh, the row shows the refresh status instead.
        var title;
        if (holding) {
            title = mView.status();
        } else {
            title = (mView.current() + 1) + "/" + p.size();
            var label = mView.currentLabel();
            if (label != null) {
                title = title + "   " + label;
                var off = mView.currentOffset();
                if (off != null) {
                    title = title + " " + Util.offsetStr(off);
                }
            }
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 4, Graphics.FONT_XTINY, title,
            Graphics.TEXT_JUSTIFY_CENTER);

        // Mandatory attribution, one line, centred below the radar image.
        // Romanized because the device system font carries no CJK glyphs when
        // the device language is not Japanese. Both required elements are
        // kept: JMA's "processed" notice (加工して利用, because we composite and
        // crop the tiles) and the GSI base-map credit. Sits in the gap between
        // the bottom of the image and the top of the zoom buttons.
        var imgBottom = by + bmp.getHeight();
        var attrY = (imgBottom + btnTop) / 2;
        dc.drawText(w / 2, attrY, Graphics.FONT_XTINY,
            "JMA Weather (processed) · GSI Map",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Loading/status branch of the render: status line, optional download
    // progress (or activity dots), and the load-time disclaimer – measured and
    // drawn as one block that is vertically centred on the screen.
    hidden function drawLoadingScreen(dc) {
        var p = mView.pipeline();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var fhSmall = dc.getFontHeight(Graphics.FONT_SMALL);
        var fhTiny = dc.getFontHeight(Graphics.FONT_XTINY);
        var hasProg = p.size() > 0;
        // Before the frame list arrives there's no per-frame progress to show,
        // so a transfer in flight (the /frames fetch) gets animated dots.
        var showDots = !hasProg && mView.isBusy();
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
        dc.drawText(w / 2, y, Graphics.FONT_SMALL, mView.status(),
            Graphics.TEXT_JUSTIFY_CENTER);
        y += fhSmall;

        // Once the frame list is known, show download progress under the
        // status: a "loaded / total" count plus a bar, so the wait while
        // the first frames stream over BLE isn't a blank "Loading..." screen.
        if (hasProg) {
            y += headGap;
            dc.drawText(w / 2, y, Graphics.FONT_XTINY,
                p.loadedCount() + " / " + p.size(),
                Graphics.TEXT_JUSTIFY_CENTER);
            y += fhTiny + gap;
            var barW = w / 2;
            drawSegmentedBar(dc, (w - barW) / 2, y, barW, 6, p.size(), p.inflightIndex());
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

    // ---- Bottom buttons ----------------------------------------------------
    // The bottom edge holds one of two controls: the Wide/Local zoom selector
    // (both shown, current highlighted) once radar is showing, or a single
    // Retry button after a failure. All share this bottom edge.
    //
    // Interaction note: the carousel (loop) view never gets coordinate-bearing
    // taps, but the pushed detail view does (see RadarView.enterDetail). These
    // rects are the geometry its onTap hit-tests (RadarView.onScreenTap).

    // One centred button (Retry), pinned to the bottom edge.
    function bottomButtonRect() as Lang.Array<Lang.Number> {
        var bw = (mW * 6) / 10;          // ~60% of the width, centred
        return [(mW - bw) / 2, buttonTop(), bw, BUTTON_H];
    }

    // The two zoom-selector buttons [left=Wide, right=Local], same bottom edge
    // as the Retry button.
    function zoomButtonRects() as Lang.Array<Lang.Array<Lang.Number>> {
        var bw = (mW * 4) / 10;          // each button ~40% of the width
        var gap = mW / 20;
        var bx = (mW - (bw * 2 + gap)) / 2;
        return [
            [bx, buttonTop(), bw, BUTTON_H],               // left  -> Wide
            [bx + bw + gap, buttonTop(), bw, BUTTON_H]     // right -> Local
        ];
    }

    function hasLayout() as Lang.Boolean {
        return mW > 0;
    }

    hidden function buttonTop() as Lang.Number {
        return mH - BUTTON_H - BUTTON_MARGIN;
    }

    hidden function drawBottomButton(dc, label) {
        if (mW <= 0) { return; }
        var r = bottomButtonRect();
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(r[0], r[1], r[2], r[3], 4);
        drawButtonLabel(dc, r, label, Graphics.COLOR_WHITE);
    }

    hidden function drawZoomButtons(dc) {
        if (mW <= 0) { return; }
        var r = zoomButtonRects();
        drawZoomButton(dc, r[0], "Wide", mView.zoom() == ZOOM_WIDE);
        drawZoomButton(dc, r[1], "Local", mView.zoom() == ZOOM_LOCAL);
    }

    // A selected button is filled blue with white text (the current level). An
    // unselected one is a grey outline with grey text (the level a tap switches
    // to).
    hidden function drawZoomButton(dc, r as Lang.Array<Lang.Number>, label, selected) {
        if (selected) {
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(r[0], r[1], r[2], r[3], 4);
            drawButtonLabel(dc, r, label, Graphics.COLOR_WHITE);
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(r[0], r[1], r[2], r[3], 4);
            drawButtonLabel(dc, r, label, Graphics.COLOR_LT_GRAY);
        }
    }

    hidden function drawButtonLabel(dc, r as Lang.Array<Lang.Number>, label, colour) {
        dc.setColor(colour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(r[0] + r[2] / 2, r[1] + r[3] / 2, Graphics.FONT_XTINY, label,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Draw a per-frame progress bar: one cell per frame so each transfer is
    // visible individually. A loaded cell is solid white (done). A permanently
    // failed cell (out of retries / non-retryable) is solid red – it can still
    // turn white later if an abandoned transfer's late arrival is salvaged. The
    // in-flight cell (activeIdx) pulses between two greys so the active
    // transfer reads as "working". A not-yet-started cell is a dim outline.
    // Used both on the loading screen and as a slim top-edge indicator during
    // playback.
    hidden function drawSegmentedBar(dc, x, y, w, h, n, activeIdx) {
        if (n <= 0) { return; }
        var p = mView.pipeline();
        var sgap = (n > 1) ? 2 : 0;
        var cellW = (w - sgap * (n - 1)) / n;
        if (cellW < 1) { cellW = 1; }
        var blinkOn = (mView.busyTick() % 2) == 0;
        var cx = x;
        for (var i = 0; i < n; i += 1) {
            if (p.isFrameLoaded(i)) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(cx, y, cellW, h);
            } else if (p.isFrameFailed(i)) {
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
    hidden function drawActivityDots(dc, cx, cy) {
        var dots = 3;
        var r = 2;
        var spacing = 8;
        var startX = cx - ((dots - 1) * spacing) / 2;
        var active = mView.busyTick() % dots;
        for (var i = 0; i < dots; i += 1) {
            dc.setColor((i == active) ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY,
                Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(startX + i * spacing, cy, r);
        }
    }
}

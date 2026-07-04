using Toybox.WatchUi;

// Input for the pushed detail view (RadarDetailView). Here -- unlike the widget
// carousel loop view -- taps arrive as onTap WITH coordinates, so we hit-test
// the on-screen buttons: Wide/Local switch the zoom, Retry re-loads after a
// failure, and a press anywhere else does nothing. Back pops us out to the loop
// view (which keeps playing the radar underneath).
class RadarDetailDelegate extends WatchUi.BehaviorDelegate {

    hidden var mRadar;

    function initialize(radar) {
        BehaviorDelegate.initialize();
        mRadar = radar;
    }

    // Coordinate-bearing tap: hit-test the buttons. Consume it either way so a
    // press off every button does nothing (no fall-through to a SELECT action).
    function onTap(evt) {
        var c = evt.getCoordinates();
        mRadar.onScreenTap(c[0], c[1]);
        return true;
    }

    // Back returns to the carousel loop view; the shared load keeps running.
    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}

using Toybox.WatchUi;

// Full-screen detail view, pushed when the user enters the radar widget from the
// carousel (see RadarView.enterDetail). Its whole reason to exist: a PUSHED view
// receives coordinate-bearing taps (onTap), which the widget-carousel loop view
// never does -- so this is the view whose on-screen buttons can be individually
// hit-tested.
//
// It owns no state of its own. It shares the loop view's RadarView instance for
// both loading/playback state AND rendering (draw), so entering the detail view
// only "unlocks" the buttons -- the radar keeps loading and animating exactly as
// it was in the loop, with no reload.
class RadarDetailView extends WatchUi.View {

    hidden var mRadar;

    function initialize(radar) {
        View.initialize();
        mRadar = radar;
    }

    // Keep the shared button geometry in sync with this view's dc (same screen,
    // so this is belt-and-suspenders, but it guarantees renderer and hit-test
    // agree even if the two views ever report different sizes).
    function onLayout(dc) {
        mRadar.onLayout(dc);
    }

    // Render the shared RadarView -- identical pixels to the loop view.
    function onUpdate(dc) {
        mRadar.draw(dc);
    }
}

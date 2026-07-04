using Toybox.WatchUi;

// Input for the widget-carousel (loop) view.
//
// Input reality on the Edge widget: the LOOP VIEW NEVER RECEIVES COORDINATES. A
// screen tap is delivered only as the coordinate-less SELECT behaviour
// (onSelect) -- InputDelegate.onTap/onScreenPress never fire for the loop view
// of a widget on Edge devices (verified in the simulator). So SELECT here can't
// be pinned to a button; instead it "enters" the widget by pushing the
// interactive detail view (RadarDetailView), which -- being a pushed view --
// DOES receive coordinate-bearing onTap, so its buttons become individually
// tappable. See RadarView.enterDetail.
class RadarDelegate extends WatchUi.BehaviorDelegate {

    hidden var mView;

    function initialize(view) {
        BehaviorDelegate.initialize();
        mView = view;
    }

    // Coordinate-less select -- the tap/press path the loop view gets. Enter the
    // interactive detail view rather than acting here (where we can't tell which
    // button, if any, was hit).
    function onSelect() {
        mView.enterDetail();
        return true;
    }

    // Allow normal back behavior to dismiss the widget from the loop.
    function onBack() {
        return false;
    }
}

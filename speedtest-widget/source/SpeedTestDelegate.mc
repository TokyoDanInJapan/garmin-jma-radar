using Toybox.WatchUi;

// Input for the speed-test view: a tap/select resets the collected stats; back
// dismisses the widget. The test loop runs on its own timer regardless.
class SpeedTestDelegate extends WatchUi.BehaviorDelegate {

    hidden var mView;

    function initialize(view) {
        BehaviorDelegate.initialize();
        mView = view;
    }

    function onSelect() {
        mView.resetStats();
        return true;
    }

    function onTap(evt) {
        mView.resetStats();
        return true;
    }

    function onBack() {
        return false;
    }
}

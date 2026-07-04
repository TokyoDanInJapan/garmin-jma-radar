using Toybox.Application;
using Toybox.WatchUi;

// Widget entry point for the Proxy Speed Test diagnostic.
class SpeedTestApp extends Application.AppBase {

    hidden var mView;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
    }

    function onStop(state) {
    }

    function getInitialView() {
        mView = new SpeedTestView();
        return [ mView, new SpeedTestDelegate(mView) ];
    }

    // Re-read proxy URL/key when the user edits settings in Garmin Connect.
    function onSettingsChanged() {
        if (mView != null) {
            mView.onSettingsChanged();
        }
    }
}

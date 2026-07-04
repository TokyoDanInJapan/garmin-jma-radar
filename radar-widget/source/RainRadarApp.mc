using Toybox.Application;
using Toybox.WatchUi;

// Widget entry point. Wires up the single radar view + its input delegate.
class RainRadarApp extends Application.AppBase {

    hidden var mView;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
    }

    function onStop(state) {
    }

    // Widgets return their initial view here.
    function getInitialView() {
        mView = new RadarView();
        return [ mView, new RadarDelegate(mView) ];
    }

    // Fired when the user edits app settings in Garmin Connect. Re-read config
    // and reload so changes (proxy URL, key, zoom, frames) take effect live.
    function onSettingsChanged() {
        if (mView != null) {
            mView.onSettingsChanged();
        }
    }
}

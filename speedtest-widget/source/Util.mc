using Toybox.Lang;

// Pure, side-effect-free helpers for the speed-test view: URL normalisation and
// duration formatting. Kept out of the view so they can be unit-tested without a
// WatchUi/Communications/Application context (see UtilTest.mc) – the view is hard
// to instantiate in a test, these are trivial to call. Mirrors the radar widget's
// Util/UtilTest split (stripSlash is intentionally the same, because each
// app stays
// self-contained rather than sharing a source tree across two separate projects).
module Util {

    // Strip any trailing "/" from the proxy base so we don't build "host//frames".
    function stripSlash(s as Lang.String) as Lang.String {
        while (s.length() > 0 && s.substring(s.length() - 1, s.length()).equals("/")) {
            s = s.substring(0, s.length() - 1);
        }
        return s;
    }

    // Why the proxy settings can't work, or null if they look usable. Same rules
    // as the radar's Util.settingsError: the shipped URL is a placeholder, and
    // plain http is refused except for a proxy on this machine.
    function settingsError(base as Lang.String, key as Lang.String) as Lang.String or Null {
        if (base.length() == 0 || base.find("YOURNAME") != null) { return "Set Proxy URL in settings"; }
        if (base.find("https://") != 0
                && base.find("http://localhost") != 0 && base.find("http://127.0.0.1") != 0) {
            return "Proxy URL must be https";
        }
        if (key.length() == 0) { return "Set Proxy key in settings"; }
        return null;
    }

    // Format a millisecond duration as "N.Ns" (one decimal) for the live clock.
    function secsStr(ms as Lang.Number) as Lang.String {
        return (ms.toFloat() / 1000.0).format("%.1f") + "s";
    }
}

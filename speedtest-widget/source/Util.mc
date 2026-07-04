using Toybox.Lang;

// Pure, side-effect-free helpers for the speed-test view: URL normalisation and
// duration formatting. Kept out of the view so they can be unit-tested without a
// WatchUi/Communications/Application context (see UtilTest.mc) -- the view is hard
// to instantiate in a test, these are trivial to call. Mirrors the radar widget's
// Util/UtilTest split (stripSlash is intentionally the same; each app stays
// self-contained rather than sharing a source tree across two separate projects).
module Util {

    // Strip any trailing "/" from the proxy base so we don't build "host//frames".
    function stripSlash(s as Lang.String) as Lang.String {
        while (s.length() > 0 && s.substring(s.length() - 1, s.length()).equals("/")) {
            s = s.substring(0, s.length() - 1);
        }
        return s;
    }

    // Format a millisecond duration as "N.Ns" (one decimal) for the live clock.
    function secsStr(ms as Lang.Number) as Lang.String {
        return (ms.toFloat() / 1000.0).format("%.1f") + "s";
    }
}

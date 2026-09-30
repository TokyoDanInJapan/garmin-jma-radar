using Toybox.Lang;

// Pure, side-effect-free helpers used by the radar view: string/number munging
// and response-code formatting. Kept out of RadarView so they can be unit-tested
// without a WatchUi/Communications/Application context (see UtilTest.mc) – the
// view itself is hard to instantiate in a test, these are trivial to call.
module Util {

    // Clamp a number to [lo, hi]. A null value (for example, a missing setting) snaps to
    // the low end so callers always get a usable number back.
    function clampNum(v as Lang.Number or Null, lo as Lang.Number, hi as Lang.Number) as Lang.Number {
        if (v == null) { return lo; }
        if (v < lo) { return lo; }
        if (v > hi) { return hi; }
        return v;
    }

    // Frames to request for the current connection. `setting` is the user's
    // frameCount (the Wi-Fi maximum). On Wi-Fi the image path is fast so we load
    // them all. Otherwise (Bluetooth, or unknown) throttle to `cap`, since image
    // pulls are ~30x slower over BLE (Garmin's image service). Never exceeds the
    // setting – a user who picked fewer than the cap keeps their choice.
    function frameCountFor(setting as Lang.Number, isWifi as Lang.Boolean, cap as Lang.Number) as Lang.Number {
        if (!isWifi && setting > cap) { return cap; }
        return setting;
    }

    // Strip any trailing "/" characters from a string. Used to normalise the
    // user-entered proxy URL so we don't build "https://host//frames".
    function stripSlash(s as Lang.String) as Lang.String {
        while (s.length() > 0 && s.substring(s.length() - 1, s.length()).equals("/")) {
            s = s.substring(0, s.length() - 1);
        }
        return s;
    }

    // Split a string on a (single- or multi-char) delimiter. Monkey C has no
    // String.split, and find() has no start offset, so walk the remainder.
    function splitStr(s as Lang.String, delim as Lang.String) as Lang.Array<Lang.String> {
        var out = [] as Lang.Array<Lang.String>;
        var rest = s;
        while (true) {
            var i = rest.find(delim);
            if (i == null) { out.add(rest); break; }
            out.add(rest.substring(0, i));
            rest = rest.substring(i + delim.length(), rest.length());
        }
        return out;
    }

    // Parse a "k1=v1&k2=v2" query string into a params Dictionary. Pairs without
    // an "=" are skipped. makeImageRequest won't accept a query string embedded in
    // the URL (it encodes the "?" into the path, so the proxy 404s), so a tile
    // URL's query has to be handed over as the params dictionary instead.
    function queryToParams(query as Lang.String) as Lang.Dictionary {
        var params = {} as Lang.Dictionary;
        var pairs = splitStr(query, "&");
        for (var i = 0; i < pairs.size(); i += 1) {
            var eq = pairs[i].find("=");
            if (eq != null) {
                params.put(pairs[i].substring(0, eq),
                           pairs[i].substring(eq + 1, pairs[i].length()));
            }
        }
        return params;
    }

    // Format a frame offset: 0 -> "now", positive -> "+30m", negative -> "-15m".
    function offsetStr(off as Lang.Number) as Lang.String {
        if (off == 0) { return "now"; }
        return ((off > 0) ? "+" : "") + off + "m";
    }

    // Retry server/transport errors (5xx, rate-limit, BLE/network) – these are
    // transient, most often Garmin's image-fetch service flaking on a tile the
    // proxy itself serves fine. Don't retry auth/4xx. Those won't fix themselves.
    // Nor will three transport codes that describe the request, not the link:
    // a response too large (-402) or out of memory (-403) fails the same way
    // again, and over BLE each retry can take ~90 s to do so, and an http://
    // proxy URL (-1001) needs a settings change.
    function isRetryable(code as Lang.Number) as Lang.Boolean {
        if (code == -402 || code == -403 || code == -1001) { return false; }
        return code <= 0 || code == 429 || code >= 500;
    }

    // Map a Communications response code to a short user-facing message.
    // Positive values are the HTTP status from the proxy, with its own failure
    // modes called out: bad coordinates (400), auth (401), rate limit (429) and
    // upstream/render errors (5xx). Zero and negative values are Connect IQ
    // transport codes. 0 is this app's own "no callback in time" (the watchdogs).
    function httpErrorMsg(code as Lang.Number) as Lang.String {
        if (code == 0)     { return "No connection"; }
        if (code == -104)  { return "Phone not connected"; }
        if (code == -2 || code == -300) { return "Timed out"; }
        if (code == -402 || code == -403) { return "Image too large"; }
        if (code == -1001) { return "Proxy URL must be https"; }
        if (code < 0)      { return "Network error (" + code + ")"; }
        if (code == 400)   { return "Outside Japan?"; }
        if (code == 401)   { return "Auth failed: check key"; }
        if (code == 429)   { return "Server busy: try later"; }
        if (code >= 500)   { return "Server error (" + code + ")"; }
        return "Request failed (" + code + ")";
    }

    // Why the proxy settings can't work, or null if they look usable. The
    // shipped default URL is a placeholder, so treat it like an empty one. The
    // key travels with every request, so plain http is refused, except for a
    // proxy on this machine (wrangler dev in the simulator).
    function settingsError(base as Lang.String, key as Lang.String) as Lang.String or Null {
        if (base.length() == 0 || base.find("YOURNAME") != null) { return "Set Proxy URL in settings"; }
        if (base.find("https://") != 0
                && base.find("http://localhost") != 0 && base.find("http://127.0.0.1") != 0) {
            return "Proxy URL must be https";
        }
        if (key.length() == 0) { return "Set Proxy key in settings"; }
        return null;
    }

    // A coordinate as a 3-decimal string (~110 m). The proxy rounds the same way
    // for its tile URLs, and the device never needs more to pick a radar tile, so
    // the exact position never leaves the device.
    function coordStr(v as Lang.Float or Lang.Double) as Lang.String {
        return v.format("%.3f");
    }

    // The /frames "frames" value as a list of at most `max` URL strings, or null
    // if it isn't a non-empty Array of Strings. The `as` casts in Monkey C do no
    // run-time checking, so an unexpected body would otherwise crash on .size()
    // or .find(). Capped because a seventh frame runs the device out of memory,
    // and a different proxy could ignore the n= limit.
    function frameList(v, max as Lang.Number) as Lang.Array<Lang.String> or Null {
        if (!(v instanceof Lang.Array) || v.size() == 0) { return null; }
        var n = (v.size() > max) ? max : v.size();
        for (var i = 0; i < n; i += 1) {
            if (!(v[i] instanceof Lang.String)) { return null; }
        }
        return v.slice(0, n) as Lang.Array<Lang.String>;
    }

    // The first n items of an optional per-frame array (labels are Strings,
    // offsets are Numbers), or null when it is missing, too short or holds the
    // wrong type. Null just hides the label, so it is always a safe answer.
    function perFrame(v, n as Lang.Number, numbers as Lang.Boolean) as Lang.Array or Null {
        if (!(v instanceof Lang.Array) || v.size() < n) { return null; }
        for (var i = 0; i < n; i += 1) {
            var ok = numbers ? (v[i] instanceof Lang.Number) : (v[i] instanceof Lang.String);
            if (!ok) { return null; }
        }
        return v.slice(0, n);
    }

    // The frame to show on the next playback tick. Frames stream in oldest to
    // newest. While loading, only move FORWARDS to the next loaded frame and hold
    // on the newest one until a newer frame arrives, so the time shown climbs
    // steadily. Looping the whole set while loading would wrap back to -15m on
    // every lap. Once loading is done, wrap around, so a missing frame can't
    // freeze playback at a gap. With nothing loaded, stay put.
    function nextFrame(cur as Lang.Number, loaded as Lang.Array<Lang.Boolean>, done as Lang.Boolean) as Lang.Number {
        var n = loaded.size();
        for (var i = cur + 1; i < n; i += 1) {
            if (loaded[i]) { return i; }
        }
        if (!done) { return cur; }
        for (var i = 0; i < n; i += 1) {
            if (loaded[i]) { return i; }
        }
        return cur;
    }
}

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
    function isRetryable(code as Lang.Number) as Lang.Boolean {
        return code <= 0 || code == 429 || code >= 500;
    }

    // Map a Communications response code to a short user-facing message. CIQ
    // reports transport failures (phone/BLE/network down) as zero/negative
    // codes. Positive values are the HTTP status from the proxy. The proxy's
    // own failure modes are called out explicitly: auth (401), rate-limit (429),
    // and upstream/render errors (5xx).
    function httpErrorMsg(code as Lang.Number) as Lang.String {
        if (code <= 0)   { return "No phone connection"; }
        if (code == 401) { return "Auth failed: check key"; }
        if (code == 429) { return "Server busy: try later"; }
        if (code >= 500) { return "Server error (" + code + ")"; }
        return "Request failed (" + code + ")";
    }
}

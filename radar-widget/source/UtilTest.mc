using Toybox.Test;
using Toybox.Lang;

// Unit tests for the pure helpers in Util. Functions annotated (:test) are only
// compiled into a unit-test build (monkeyc --unit-test ...) and run in the
// simulator via `monkeydo <prg> -t`; they are excluded from release builds, so
// they add no on-device size. Each takes a Test.Logger and returns true on pass.
//
// Run locally:
//   monkeyc -f monkey.jungle -o bin/test.prg -y <dev_key> -d edge1040 --unit-test
//   monkeydo bin/test.prg edge1040 -t

// ---- clampNum --------------------------------------------------------------
(:test)
function testClampNumWithinRange(logger) {
    return Util.clampNum(5, 1, 10) == 5;
}

(:test)
function testClampNumBelowAndAbove(logger) {
    return Util.clampNum(0, 1, 10) == 1
        && Util.clampNum(99, 1, 10) == 10;
}

(:test)
function testClampNumBoundsInclusive(logger) {
    return Util.clampNum(1, 1, 10) == 1
        && Util.clampNum(10, 1, 10) == 10;
}

(:test)
function testClampNumNullSnapsToLow(logger) {
    // A missing setting reads as null; it must snap to the low bound.
    return Util.clampNum(null, 1, 6) == 1;
}

// ---- frameCountFor ---------------------------------------------------------
(:test)
function testFrameCountForWifiLoadsAll(logger) {
    // Wi-Fi is the fast path: request the full setting.
    return Util.frameCountFor(6, true, 3) == 6;
}

(:test)
function testFrameCountForBluetoothThrottlesToCap(logger) {
    // Over BLE, throttle down to the cap.
    return Util.frameCountFor(6, false, 3) == 3;
}

(:test)
function testFrameCountForBelowCapKeptOnEitherPath(logger) {
    // A user choice already at/under the cap is never raised.
    return Util.frameCountFor(2, false, 3) == 2
        && Util.frameCountFor(2, true, 3) == 2;
}

(:test)
function testFrameCountForAtCapUnchanged(logger) {
    return Util.frameCountFor(3, false, 3) == 3;
}

// ---- stripSlash ------------------------------------------------------------
(:test)
function testStripSlashTrailing(logger) {
    return Util.stripSlash("https://host/").equals("https://host");
}

(:test)
function testStripSlashMultipleTrailing(logger) {
    return Util.stripSlash("https://host///").equals("https://host");
}

(:test)
function testStripSlashNoneToStrip(logger) {
    return Util.stripSlash("https://host").equals("https://host");
}

(:test)
function testStripSlashEmpty(logger) {
    return Util.stripSlash("").equals("");
}

// ---- splitStr --------------------------------------------------------------
(:test)
function testSplitStrBasic(logger) {
    var parts = Util.splitStr("a=1&b=2&c=3", "&");
    return parts.size() == 3
        && parts[0].equals("a=1")
        && parts[1].equals("b=2")
        && parts[2].equals("c=3");
}

(:test)
function testSplitStrNoDelimiter(logger) {
    var parts = Util.splitStr("lonely", "&");
    return parts.size() == 1 && parts[0].equals("lonely");
}

(:test)
function testSplitStrTrailingDelimiterYieldsEmpty(logger) {
    // "a&" -> ["a", ""]: the walk emits the empty remainder after the last "&".
    var parts = Util.splitStr("a&", "&");
    return parts.size() == 2 && parts[0].equals("a") && parts[1].equals("");
}

(:test)
function testSplitStrMultiCharDelimiter(logger) {
    var parts = Util.splitStr("a::b::c", "::");
    return parts.size() == 3
        && parts[0].equals("a") && parts[1].equals("b") && parts[2].equals("c");
}

// ---- queryToParams ---------------------------------------------------------
(:test)
function testQueryToParamsBasic(logger) {
    var p = Util.queryToParams("lat=35.6&z=10&basetime=20260101000000");
    return p.size() == 3
        && p.get("lat").equals("35.6")
        && p.get("z").equals("10")
        && p.get("basetime").equals("20260101000000");
}

(:test)
function testQueryToParamsSkipsMalformed(logger) {
    // A bare token with no "=" is ignored rather than producing a junk entry.
    var p = Util.queryToParams("a=1&garbage&b=2");
    return p.size() == 2 && p.get("a").equals("1") && p.get("b").equals("2");
}

(:test)
function testQueryToParamsValueKeepsEquals(logger) {
    // Only the first "=" splits; any "=" in the value is preserved.
    var p = Util.queryToParams("k=a=b");
    return p.get("k").equals("a=b");
}

// ---- offsetStr -------------------------------------------------------------
(:test)
function testOffsetStrNow(logger) {
    return Util.offsetStr(0).equals("now");
}

(:test)
function testOffsetStrPositive(logger) {
    return Util.offsetStr(30).equals("+30m");
}

(:test)
function testOffsetStrNegative(logger) {
    return Util.offsetStr(-15).equals("-15m");
}

// ---- isRetryable -----------------------------------------------------------
(:test)
function testIsRetryableTransient(logger) {
    // <=0 transport failures, 429 rate-limit, and 5xx are all retryable.
    return Util.isRetryable(0)
        && Util.isRetryable(-1)
        && Util.isRetryable(429)
        && Util.isRetryable(500)
        && Util.isRetryable(503);
}

(:test)
function testIsRetryableNotForClientErrors(logger) {
    // 200 success and 4xx (auth/bad request) must NOT be retried.
    return !Util.isRetryable(200)
        && !Util.isRetryable(401)
        && !Util.isRetryable(404);
}

// ---- httpErrorMsg ----------------------------------------------------------
(:test)
function testHttpErrorMsgTransport(logger) {
    return Util.httpErrorMsg(0).equals("No phone connection")
        && Util.httpErrorMsg(-5).equals("No phone connection");
}

(:test)
function testHttpErrorMsgAuthAndRateLimit(logger) {
    return Util.httpErrorMsg(401).equals("Auth failed - check key")
        && Util.httpErrorMsg(429).equals("Server busy - try later");
}

(:test)
function testHttpErrorMsgServerErrorIncludesCode(logger) {
    return Util.httpErrorMsg(503).equals("Server error (503)");
}

(:test)
function testHttpErrorMsgFallbackIncludesCode(logger) {
    // An unclassified positive status (e.g. 418) falls through to the generic.
    return Util.httpErrorMsg(418).equals("Request failed (418)");
}

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

// ---- secsStr ---------------------------------------------------------------
(:test)
function testSecsStrFormatsOneDecimal(logger) {
    return Util.secsStr(0).equals("0.0s")
        && Util.secsStr(1500).equals("1.5s")
        && Util.secsStr(27000).equals("27.0s");
}

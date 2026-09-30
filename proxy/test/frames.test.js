import { test } from "node:test";
import assert from "node:assert/strict";
import { getFrameTimes } from "../src/jma.js";
import { ANCHOR, OBSERVED, FORECAST, stubFetch } from "./helpers.js";
import { clearMemos } from "../src/memo.js";

// getFrameTimes hits JMA's targetTimes endpoints through global fetch and an
// in-memory cache. stubFetch (helpers.js) serves canned N1/N2 bodies keyed off
// the URL and clears that cache, so each test sees its own bodies.

const offsetsOf = (frames) => frames.map((f) => f.offset);

test("default returns the full -15..+60 window, oldest-first", async () => {
  stubFetch();
  const frames = await getFrameTimes();
  assert.deepEqual(offsetsOf(frames), [-15, 0, 15, 30, 45, 60]);
});

test("count selects highest-priority frames (now, +60, +30) then sorts by time", async () => {
  stubFetch();
  const frames = await getFrameTimes(3);
  assert.deepEqual(offsetsOf(frames), [0, 30, 60]);
});

test("count=1 keeps only 'now'", async () => {
  stubFetch();
  const frames = await getFrameTimes(1);
  assert.deepEqual(offsetsOf(frames), [0]);
});

test("count is clamped to the 6-frame device ceiling", async () => {
  stubFetch();
  const frames = await getFrameTimes(12);
  assert.deepEqual(offsetsOf(frames), [-15, 0, 15, 30, 45, 60]);
});

test("a 0/invalid count falls back to the full set", async () => {
  stubFetch();
  assert.deepEqual(offsetsOf(await getFrameTimes(0)), [-15, 0, 15, 30, 45, 60]);
  assert.deepEqual(offsetsOf(await getFrameTimes(NaN)), [-15, 0, 15, 30, 45, 60]);
});

test("a missing offset is replaced by the next one in priority order", async () => {
  // Drop the +45 forecast frame. A count of 4 (priority now,+60,+30,+45) then
  // moves on to +15 rather than returning three frames.
  stubFetch(OBSERVED, FORECAST.filter((f) => f.validtime !== "20260627124500"));
  const frames = await getFrameTimes(4);
  assert.deepEqual(offsetsOf(frames), [0, 15, 30, 60]);
});

test("'now' survives when N1 lags N2 by one step", async () => {
  // N2 has moved on to a 12:05 analysis, but the cached N1 still ends at 12:00.
  const next = "20260627120500";
  const fc = FORECAST.map((f) => ({ basetime: next, validtime: f.validtime }))
    .concat({ basetime: next, validtime: "20260627131000" });
  stubFetch(OBSERVED, fc);
  const frames = await getFrameTimes(1);
  assert.deepEqual(frames, [{ basetime: ANCHOR, validtime: ANCHOR, offset: 0 }]);
});

test("a mixed-run N2 list uses only the newest basetime", async () => {
  const older = FORECAST.map((f) => ({ basetime: "20260627115500", validtime: f.validtime }));
  stubFetch(OBSERVED, older.concat(FORECAST));
  const frames = await getFrameTimes();
  assert.ok(frames.filter((f) => f.offset > 0).every((f) => f.basetime === ANCHOR));
});

test("null and malformed entries in targetTimes are ignored", async () => {
  stubFetch([null, { basetime: "20261327120000", validtime: "20261327120000" }, ...OBSERVED], FORECAST);
  const frames = await getFrameTimes();
  assert.deepEqual(offsetsOf(frames), [-15, 0, 15, 30, 45, 60]);
});

test("frame lists are cached in memory between calls", async () => {
  stubFetch();
  let calls = 0;
  const inner = globalThis.fetch;
  globalThis.fetch = async (u, init) => { calls++; return inner(u, init); };
  await getFrameTimes();
  await getFrameTimes();
  assert.equal(calls, 2); // N1 + N2 once, then memory hits
  clearMemos();
});

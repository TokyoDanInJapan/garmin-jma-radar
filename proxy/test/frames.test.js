import { test } from "node:test";
import assert from "node:assert/strict";
import { getFrameTimes } from "../src/jma.js";
import { CTX, OBSERVED, FORECAST, stubCaches, stubFetch } from "./helpers.js";

// getFrameTimes hits JMA's targetTimes endpoints through global fetch + the
// Workers cache. The shared stubs (helpers.js) make the cache always miss (so
// fetch is exercised) and serve canned N1/N2 bodies keyed off the URL.
stubCaches();

const offsetsOf = (frames) => frames.map((f) => f.offset);

test("default returns the full -15..+60 window, oldest-first", async () => {
  stubFetch();
  const frames = await getFrameTimes({}, CTX);
  assert.deepEqual(offsetsOf(frames), [-15, 0, 15, 30, 45, 60]);
});

test("count selects highest-priority frames (now, +60, +30) then sorts by time", async () => {
  stubFetch();
  const frames = await getFrameTimes({}, CTX, 3);
  assert.deepEqual(offsetsOf(frames), [0, 30, 60]);
});

test("count=1 keeps only 'now'", async () => {
  stubFetch();
  const frames = await getFrameTimes({}, CTX, 1);
  assert.deepEqual(offsetsOf(frames), [0]);
});

test("count is clamped to the 6-frame device ceiling", async () => {
  stubFetch();
  const frames = await getFrameTimes({}, CTX, 12);
  assert.deepEqual(offsetsOf(frames), [-15, 0, 15, 30, 45, 60]);
});

test("a 0/invalid count falls back to the full set", async () => {
  stubFetch();
  assert.deepEqual(offsetsOf(await getFrameTimes({}, CTX, 0)), [-15, 0, 15, 30, 45, 60]);
  assert.deepEqual(offsetsOf(await getFrameTimes({}, CTX, NaN)), [-15, 0, 15, 30, 45, 60]);
});

test("offsets JMA doesn't currently have are silently skipped", async () => {
  // Drop the +45 forecast frame. A count of 4 (priority now,+60,+30,+45) then
  // yields only the three that exist.
  stubFetch(OBSERVED, FORECAST.filter((f) => f.validtime !== "20260627124500"));
  const frames = await getFrameTimes({}, CTX, 4);
  assert.deepEqual(offsetsOf(frames), [0, 30, 60]);
});

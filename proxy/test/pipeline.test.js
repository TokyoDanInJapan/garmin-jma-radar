import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { ENV, CTX, installDefaults } from "./helpers.js";

// End-to-end tests for the request pipeline (handleFrames / handleTile and the
// fetchNeighbourhood -> fetchTilePNG -> composite path). The auth/validation
// layer is covered in handler.test.js. Here the shared stubs (helpers.js) for
// global fetch + caches let the requests run all the way through to a JSON
// list / composited PNG.

installDefaults();

const call = (path, env = ENV) =>
  worker.fetch(new Request(`https://proxy.test${path}`), env, CTX);

// ---- /frames ---------------------------------------------------------------

test("/frames returns ordered tile URLs with labels and offsets", async () => {
  installDefaults();
  const r = await call("/frames?lat=35.68&lon=139.76&z=10&key=secret");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("Cache-Control"), "public, max-age=60");
  const body = await r.json();
  assert.equal(body.count, 6);
  assert.equal(body.frames.length, 6);
  assert.deepEqual(body.offsets, [-15, 0, 15, 30, 45, 60]);
  assert.equal(body.labels.length, 6);
  assert.equal(body.z, 10);
  // URLs are fully-formed /tile requests carrying the canonical params.
  assert.ok(body.frames[0].startsWith("/tile?"));
  assert.match(body.frames[0], /basetime=\d{14}/);
  assert.match(body.frames[0], /validtime=\d{14}/);
  assert.match(body.frames[0], /lat=35\.68/); // round4 preserves 4 decimals
});

test("/frames honours the n (frameCount) cap and priority order", async () => {
  installDefaults();
  const r = await call("/frames?lat=35.68&lon=139.76&z=10&n=3&key=secret");
  const body = await r.json();
  assert.equal(body.count, 3);
  assert.deepEqual(body.offsets, [0, 30, 60]); // priority now,+60,+30 -> time order
});

test("/frames surfaces an upstream targetTimes failure as 502", async () => {
  globalThis.fetch = async () => new Response("err", { status: 500 });
  try {
    const r = await call("/frames?lat=35.68&lon=139.76&z=10&key=secret");
    assert.equal(r.status, 502);
  } finally {
    installDefaults();
  }
});

// ---- /tile -----------------------------------------------------------------

test("/tile composites and returns an immutable PNG frame", async () => {
  installDefaults();
  const r = await call("/tile?lat=35.68&lon=139.76&z=10&basetime=20260627120000&validtime=20260627123000&key=secret");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("Content-Type"), "image/png");
  assert.match(r.headers.get("Cache-Control"), /immutable/);
  const bytes = new Uint8Array(await r.arrayBuffer());
  assert.deepEqual([...bytes.slice(0, 4)], [0x89, 0x50, 0x4e, 0x47]); // PNG magic
});

test("/tile serves directly from the edge cache on a hit", async () => {
  const cached = new Response("CACHED", { status: 200, headers: { "Content-Type": "image/png" } });
  globalThis.caches = { default: { match: async () => cached, put: async () => {} } };
  try {
    const r = await call("/tile?lat=35.68&lon=139.76&z=10&basetime=20260627120000&validtime=20260627123000&key=secret");
    assert.equal(await r.text(), "CACHED"); // returned without compositing
  } finally {
    installDefaults();
  }
});

test("/tile still renders a frame when every upstream tile 404s", async () => {
  globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };
  globalThis.fetch = async () => new Response("nope", { status: 404 });
  try {
    const r = await call("/tile?lat=35.68&lon=139.76&z=10&basetime=20260627120000&validtime=20260627123000&key=secret");
    assert.equal(r.status, 200); // 404 tiles degrade to background, not an error
    assert.equal(r.headers.get("Content-Type"), "image/png");
  } finally {
    installDefaults();
  }
});

test("/tile degrades to a frame when a tile fetch throws (network error/timeout)", async () => {
  globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };
  globalThis.fetch = async () => { throw new Error("boom"); }; // simulate AbortError/network drop
  try {
    const r = await call("/tile?lat=35.68&lon=139.76&z=10&basetime=20260627120000&validtime=20260627123000&key=secret");
    assert.equal(r.status, 200); // fetchTilePNG catches and returns null -> background
    assert.equal(r.headers.get("Content-Type"), "image/png");
  } finally {
    installDefaults();
  }
});

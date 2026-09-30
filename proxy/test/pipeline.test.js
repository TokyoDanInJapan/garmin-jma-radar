import { test, mock } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { parseJmaTime } from "../src/jma.js";
import { ANCHOR, ENV, CTX, installDefaults, stubCaches } from "./helpers.js";

// End-to-end tests for the request pipeline (handleFrames / handleTile and the
// fetchNeighbourhood -> fetchTilePNG -> composite path). The auth/validation
// layer is covered in handler.test.js. Here the shared stubs (helpers.js) for
// global fetch + caches let the requests run all the way through to a JSON
// list / composited PNG.

installDefaults();

// /tile only accepts frames from the last 3 hours, and the fixtures are pinned
// to ANCHOR, so run the clock 10 minutes after it.
mock.method(Date, "now", () => parseJmaTime(ANCHOR) + 10 * 60 * 1000);

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
  assert.match(body.frames[0], /lat=35\.68&/); // rounded to 3 decimals
});

test("/frames honours the n (frameCount) cap and priority order", async () => {
  installDefaults();
  const r = await call("/frames?lat=35.68&lon=139.76&z=10&n=3&key=secret");
  const body = await r.json();
  assert.equal(body.count, 3);
  assert.deepEqual(body.offsets, [0, 30, 60]); // priority now,+60,+30 -> time order
});

test("/frames surfaces an upstream targetTimes failure as 502", async () => {
  stubCaches(); // empty the in-memory frame lists from the tests above
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
  stubCaches(); // empty the in-memory frames, so the edge cache is asked
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

test("/tile does not cache a frame when a tile failed (not 404)", async () => {
  let puts = 0;
  globalThis.caches = { default: { match: async () => undefined, put: async () => { puts++; } } };
  const okFetch = globalThis.fetch;
  // Radar tiles 503, base tiles are fine: the frame renders but is degraded.
  globalThis.fetch = async (url, init) =>
    String(url).includes("hrpns") ? new Response("busy", { status: 503 }) : okFetch(url, init);
  try {
    const r = await call("/tile?lat=35.68&lon=139.76&z=10&basetime=20260627120000&validtime=20260627123000&key=secret");
    assert.equal(r.status, 200);
    assert.equal(r.headers.get("Cache-Control"), "no-store");
    assert.equal(puts, 0);
  } finally {
    installDefaults();
  }
});

test("/tile caches a frame whose tiles 404 (no rain is a real answer)", async () => {
  let puts = 0;
  globalThis.caches = { default: { match: async () => undefined, put: async () => { puts++; } } };
  globalThis.fetch = async () => new Response("nope", { status: 404 });
  try {
    const r = await call("/tile?lat=35.68&lon=139.76&z=10&basetime=20260627120000&validtime=20260627123000&key=secret");
    assert.match(r.headers.get("Cache-Control"), /immutable/);
    assert.equal(puts, 1);
  } finally {
    installDefaults();
  }
});

// ---- /tile validation and caching -----------------------------------------

const TILE_Q = "/tile?lat=35.68&lon=139.76&z=10&key=secret";

test("/tile rejects frame times that JMA could not have published", async () => {
  installDefaults();
  const bad = [
    ["20260627120000", "20260627130500"], // lead over 60 min
    ["20260627120000", "20260627115500"], // validtime before basetime
    ["20260627120000", "20260627120700"], // off the 5-minute grid
    ["20260627080000", "20260627080000"], // more than 3 hours old
    ["20260627123000", "20260627123000"], // in the future
    ["20261327120000", "20261327120000"], // month 13
  ];
  for (const [b, v] of bad) {
    const r = await call(`${TILE_Q}&basetime=${b}&validtime=${v}`);
    assert.equal(r.status, 400, `${b}/${v}`);
  }
});

test("/tile serves a repeat from memory without refetching upstream", async () => {
  installDefaults();
  let fetches = 0;
  const inner = globalThis.fetch;
  globalThis.fetch = async (u, init) => { fetches++; return inner(u, init); };
  try {
    const q = `${TILE_Q}&basetime=20260627120000&validtime=20260627123000`;
    const a = await call(q);
    const first = fetches;
    const b = await call(q);
    assert.equal(fetches, first); // second request made no upstream fetch
    assert.deepEqual(new Uint8Array(await a.arrayBuffer()), new Uint8Array(await b.arrayBuffer()));
  } finally {
    installDefaults();
  }
});

test("/tile reuses decoded base tiles across frames", async () => {
  installDefaults();
  const urls = [];
  const inner = globalThis.fetch;
  globalThis.fetch = async (u, init) => { urls.push(String(u)); return inner(u, init); };
  try {
    await call(`${TILE_Q}&basetime=20260627120000&validtime=20260627123000`);
    urls.length = 0;
    await call(`${TILE_Q}&basetime=20260627120000&validtime=20260627124500`);
    assert.ok(urls.length > 0);
    assert.ok(urls.every((u) => u.includes("hrpns")), "only radar tiles are fetched again");
  } finally {
    installDefaults();
  }
});

test("/tile treats a 200 that is not a PNG as a failed tile", async () => {
  installDefaults();
  globalThis.fetch = async () => new Response("<html>maintenance</html>", { status: 200 });
  try {
    const r = await call(`${TILE_Q}&basetime=20260627120000&validtime=20260627123000`);
    assert.equal(r.status, 200);
    assert.equal(r.headers.get("Cache-Control"), "no-store");
  } finally {
    installDefaults();
  }
});

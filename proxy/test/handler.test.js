import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { ENV, CTX } from "./helpers.js";

const call = (path, { env = ENV, method = "GET" } = {}) =>
  worker.fetch(new Request(`https://proxy.test${path}`, { method }), env, CTX);

// These all return at the validation/auth layer, before any upstream fetch.

test("non-GET methods are rejected with 405", async () => {
  const r = await call("/frames?lat=35&lon=139&key=secret", { method: "POST" });
  assert.equal(r.status, 405);
  assert.equal(r.headers.get("Allow"), "GET, HEAD");
});

test("missing token -> 401", async () => {
  const r = await call("/frames?lat=35&lon=139");
  assert.equal(r.status, 401);
});

test("wrong token -> 401", async () => {
  const r = await call("/frames?lat=35&lon=139&key=nope");
  assert.equal(r.status, 401);
});

test("fails closed when PROXY_TOKEN is unset, even with a key", async () => {
  const r = await call("/frames?lat=35&lon=139&key=secret", { env: {} });
  assert.equal(r.status, 401);
});

test("out-of-range (non-Japan) coordinates -> 400", async () => {
  const r = await call("/frames?lat=0&lon=0&key=secret"); // gulf of guinea
  assert.equal(r.status, 400);
});

test("malformed basetime -> 400 (no path injection reaches upstream)", async () => {
  const r = await call("/tile?lat=35&lon=139&z=10&basetime=..%2Fevil&validtime=20260618135000&key=secret");
  assert.equal(r.status, 400);
});

test("/speedtest requires a token like the other compute endpoints", async () => {
  const r = await call("/speedtest");
  assert.equal(r.status, 401);
});

test("/speedtest serves a byte-identical immutable PNG on every request", async () => {
  const a = await call("/speedtest?key=secret");
  const b = await call("/speedtest?key=secret");
  assert.equal(a.status, 200);
  assert.equal(a.headers.get("Content-Type"), "image/png");
  assert.match(a.headers.get("Cache-Control"), /immutable/);
  const ab = new Uint8Array(await a.arrayBuffer());
  const bb = new Uint8Array(await b.arrayBuffer());
  assert.deepEqual([...ab.slice(0, 4)], [0x89, 0x50, 0x4e, 0x47]); // PNG magic
  assert.deepEqual(ab, bb); // fixed asset: the size/content never varies
  // Shaped like a real frame: a realistic payload size, not a trivial blob.
  assert.ok(ab.length > 8000 && ab.length < 20000, `unexpected size ${ab.length}`);
});

test("/health needs no token and reports ok + binding status", async () => {
  const r = await call("/health");
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.equal(body.ok, true);
  assert.equal(body.rateLimiter, false); // no RATE_LIMITER bound in the test env
});

test("unknown path -> 404", async () => {
  const r = await call("/nope?key=secret");
  assert.equal(r.status, 404);
});

test("responses carry the nosniff header", async () => {
  const r = await call("/health");
  assert.equal(r.headers.get("X-Content-Type-Options"), "nosniff");
});

test("rate limiter rejects with 429 when the binding denies", async () => {
  const env = { PROXY_TOKEN: "secret", RATE_LIMITER: { limit: async () => ({ success: false }) } };
  const r = await call("/frames?lat=35&lon=139&key=secret", { env });
  assert.equal(r.status, 429);
});

test("rate limiter allows the request through (then normal validation applies)", async () => {
  const env = { PROXY_TOKEN: "secret", RATE_LIMITER: { limit: async () => ({ success: true }) } };
  // limiter passes, so we reach geoParams -> out-of-range coords -> 400 (not 429)
  const r = await call("/frames?lat=0&lon=0&key=secret", { env });
  assert.equal(r.status, 400);
});

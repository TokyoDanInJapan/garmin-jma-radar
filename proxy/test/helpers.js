import UPNG from "upng-js";

// Shared stubs and fixtures for the worker test suites: a caches.default that
// always misses, a fetch that serves canned targetTimes JSON + a solid PNG for
// any tile URL, and the fixed observed/forecast frame fixtures. Individual
// tests override globals as needed and call installDefaults() to restore.

export const ENV = { PROXY_TOKEN: "secret" };
export const CTX = { waitUntil() {} };
export const TILE = 256;

// Anchor analysis time = 12:00 UTC. Observed (N1) frames have
// basetime===validtime; forecast (N2) frames all share basetime = the anchor.
export const ANCHOR = "20260627120000";
export const OBSERVED = [
  { basetime: "20260627114500", validtime: "20260627114500" }, // -15
  { basetime: ANCHOR, validtime: ANCHOR },                      //   0 (now)
];
export const FORECAST = [
  { basetime: ANCHOR, validtime: "20260627121500" }, // +15
  { basetime: ANCHOR, validtime: "20260627123000" }, // +30
  { basetime: ANCHOR, validtime: "20260627124500" }, // +45
  { basetime: ANCHOR, validtime: "20260627130000" }, // +60
];

/** A solid-colour 256x256 tile encoded as PNG bytes, for stubbed tile fetches. */
export function solidPng([r, g, b, a]) {
  const buf = new Uint8Array(TILE * TILE * 4);
  for (let i = 0; i < buf.length; i += 4) {
    buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = a;
  }
  return new Uint8Array(UPNG.encode([buf.buffer], TILE, TILE, 0));
}
export const TILE_PNG = solidPng([120, 120, 120, 255]);

/** Install a caches.default stub that always misses (so fetch is exercised). */
export function stubCaches() {
  globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };
}

/**
 * Install a fetch stub: targetTimes URLs get JSON (N1 -> observed, everything
 * else -> forecast); any other URL (tiles) gets TILE_PNG.
 */
export function stubFetch(observed = OBSERVED, forecast = FORECAST) {
  globalThis.fetch = async (url) => {
    const u = String(url);
    if (u.includes("targetTimes")) {
      const body = u.includes("N1") ? observed : forecast;
      return new Response(JSON.stringify(body), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }
    return new Response(TILE_PNG, { status: 200, headers: { "Content-Type": "image/png" } });
  };
}

/** Reset both globals to the default stubs. */
export function installDefaults() {
  stubCaches();
  stubFetch();
}

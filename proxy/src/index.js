// @ts-check
/**
 * JMA Rain Radar proxy for Garmin Edge devices.
 *
 * Responsibilities:
 *   1. Resolve JMA's targetTimes_N2.json -> ordered list of {basetime, validtime}
 *   2. For a rider lat/lon + zoom, compute the tile that contains them
 *   3. Fetch the radar tile (+ optional base map) for each frame, composite,
 *      crop to a device-friendly size, and return a single PNG per frame.
 *   4. Cache aggressively so JMA's undocumented endpoints are hit once per
 *      frame, not once per device.
 *
 * Endpoints exposed to the device:
 *   GET /frames?lat=..&lon=..&z=10&n=6
 *       -> JSON: { frames: [ "/tile?...", ... ], labels, offsets, updated, z, count }
 *   GET /tile?lat=..&lon=..&z=10&basetime=..&validtime=..
 *       -> image/png   (rider-centered, composited, cropped)
 *   GET /speedtest
 *       -> image/png   (fixed-size synthetic frame for the speed-test widget)
 *
 * NOTE: JMA tile URLs are internal/undocumented and may change without notice.
 * Keep all JMA-specific URL construction in jma.js so it changes in one place.
 * Attribution (出典: 気象庁) + "processed" notice must be shown in the app UI.
 */

import { getFrameTimes, radarTileURL, jstLabel } from "./jma.js";
import { baseTileURL } from "./basemap.js";
import { lonLatToTileXY } from "./tilemath.js";
import { composite, speedtestPNG } from "./composite.js";

// px; fills the Edge 1030/1040 width (282px). 8-bit palette ≈ 81KB/frame on
// device. A cross-project contract: must match DEVICE_TILE_SIZE in both widgets
// (radar-widget RadarView.mc, speedtest-widget SpeedTestView.mc).
const DEVICE_TILE_SIZE = 288;
const TILE = 256; // slippy tile size; matches tilemath.js / composite.js

// Scope is Japan only (README): reject coordinates outside a generous box around
// the JMA nowcast coverage. Bounding requests here caps the cache/key space an
// attacker can reach and avoids feeding NaN-prone values into the tile math.
const JAPAN = { latMin: 20, latMax: 46, lonMin: 122, lonMax: 154 };
const Z_MIN = 4;
const Z_MAX = 11; // JMA hrpns radar + GSI base tiles 404 past z=11 -> blank frame

/** Error carrying an HTTP status so the top-level catch can map it to a response. */
class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/**
 * Gate the compute-heavy endpoints behind a shared secret. The device sends it
 * as `?key=` (easiest from Monkey C's makeImageRequest) or an `X-Proxy-Key`
 * header. PROXY_TOKEN is a Wrangler secret (`wrangler secret put PROXY_TOKEN`);
 * if it isn't configured we fail closed rather than serve an open proxy.
 */
function authorize(request, url, env) {
  const provided = url.searchParams.get("key") || request.headers.get("X-Proxy-Key") || "";
  if (!env.PROXY_TOKEN || !timingSafeEqual(provided, env.PROXY_TOKEN)) {
    throw new HttpError(401, "unauthorized");
  }
}

/** Constant-time string compare, so a bad token can't be guessed by timing. */
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Per-IP rate limit on the compute-heavy endpoints (Workers Rate Limiting
 * binding, configured in wrangler.toml). A leaked token could otherwise drive
 * cache-busting load; this caps it. No-op when the binding is absent (e.g. local
 * `wrangler dev` without it), so dev/tests don't depend on the beta binding.
 */
async function rateLimit(request, env) {
  if (!env.RATE_LIMITER) return;
  const clientIp = request.headers.get("cf-connecting-ip") || "anonymous";
  const { success } = await env.RATE_LIMITER.limit({ key: clientIp });
  if (!success) throw new HttpError(429, "rate limited");
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD", "X-Content-Type-Options": "nosniff" },
      });
    }
    try {
      switch (url.pathname) {
        case "/frames":
          authorize(request, url, env);
          await rateLimit(request, env);
          return await handleFrames(url, env, ctx);
        case "/tile":
          authorize(request, url, env);
          await rateLimit(request, env);
          return await handleTile(url, env, ctx);
        case "/speedtest":
          authorize(request, url, env);
          await rateLimit(request, env);
          return handleSpeedTest();
        case "/health":
          // Liveness probe + a non-sensitive ops flag: is the rate-limit binding
          // actually bound at runtime? (true iff wrangler.toml's RATE_LIMITER
          // deployed). Helps verify rate limiting without guessing.
          return json({ ok: true, rateLimiter: !!env.RATE_LIMITER });
        default:
          return new Response("Not found", {
            status: 404,
            headers: { "X-Content-Type-Options": "nosniff" },
          });
      }
    } catch (err) {
      // Client errors carry a safe, intentional message. Everything else may
      // embed upstream URLs/status - log it server-side, return a generic body.
      if (err instanceof HttpError) return json({ error: err.message }, err.status);
      console.error("upstream/render error:", err instanceof Error ? err.stack : err);
      return json({ error: "upstream error" }, 502);
    }
  },
};

/**
 * Return an ordered list of frame URLs (oldest -> newest) the device should
 * fetch and animate. We hand back fully-formed /tile URLs so the device does
 * zero math beyond looping the array.
 */
async function handleFrames(url, env, ctx) {
  const { lat, lon, z } = geoParams(url);

  // -15..+60 min window in 15-min steps (assembled in jma.js). `n` is the
  // device's frameCount setting: it caps how many frames we return, selected by
  // jma.js's priority order (now, +60, +30, ...) and played oldest-first.
  // Defaults to the full set; jma.js clamps it to the memory-safe maximum.
  const n = int(url, "n", 6);
  const recent = await getFrameTimes(env, ctx, n); // [{basetime, validtime, offset}, ...]

  // Round to ~11m so trivially-different fixes collapse onto the same /tile URL
  // (and the same cache entry). 4 decimals is sub-pixel at every supported zoom.
  const rlat = round4(lat);
  const rlon = round4(lon);
  const frames = recent.map((t) => {
    const q = new URLSearchParams({
      lat: String(rlat),
      lon: String(rlon),
      z: String(z),
      basetime: t.basetime,
      validtime: t.validtime,
    });
    return `/tile?${q.toString()}`;
  });
  // Per-frame JST "HH:MM" labels (absolute valid time) plus the fixed grid
  // offset in minutes from the analysis time (-15..+60). The device shows
  // "<label> <offset>" so the offset is stable and TZ-independent - no device
  // clock math. JMA validtimes are UTC; riders are in Japan, so labels are JST.
  const labels = recent.map((t) => jstLabel(t.validtime));
  const offsets = recent.map((t) => t.offset);

  return json(
    { frames, labels, offsets, updated: Math.floor(Date.now() / 1000), z, count: frames.length },
    200,
    // short cache: the frame *list* changes every ~5 min
    { "Cache-Control": "public, max-age=60" }
  );
}

/**
 * Produce a single rider-centered PNG frame. Heavily cached (immutable per
 * basetime/validtime/lat/lon/z) so JMA is hit at most once per unique frame.
 */
async function handleTile(url, env, ctx) {
  const { lat, lon, z } = geoParams(url);
  const basetime = timestamp(url, "basetime");
  const validtime = timestamp(url, "validtime");

  // Which tile contains the rider, and where inside it they sit (for centering).
  const { x, y, px, py } = lonLatToTileXY(lon, lat, z);

  // Cache on the canonical (integer) tile geometry, NOT the raw lat/lon floats.
  // Any two riders that resolve to the same tile pixel share one cache entry, so
  // sub-pixel jitter in the query string can't fan out into unbounded entries
  // (and unbounded JMA origin fetches).
  const cache = caches.default;
  const canonical = `https://radar.invalid/tile?z=${z}&x=${x}&y=${y}&px=${px}&py=${py}&b=${basetime}&v=${validtime}`;
  const cacheKey = new Request(canonical, { method: "GET" });
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  // The rider-centered window may straddle tile boundaries, so we fetch the
  // base-map and radar tiles it overlaps. A 288px window over 256px tiles touches
  // at most 3 columns/rows but usually only 2 (4 tiles), so compute the exact
  // overlap and skip the rest - fewer JMA/GSI fetches and fewer PNG decodes than
  // the old fixed 3x3. Base tiles rarely change (cache hard); radar frames are
  // per-validtime (shorter TTL).
  const dxs = windowTileOffsets(px, DEVICE_TILE_SIZE);
  const dys = windowTileOffsets(py, DEVICE_TILE_SIZE);
  const [baseTiles, radarTiles] = await Promise.all([
    fetchNeighbourhood({ x, y, dxs, dys, urlFor: (tx, ty) => baseTileURL({ z, x: tx, y: ty }), cacheTtl: 86400 }),
    fetchNeighbourhood({ x, y, dxs, dys, urlFor: (tx, ty) => radarTileURL({ z, x: tx, y: ty, basetime, validtime }), cacheTtl: 300 }),
  ]);

  const png = await composite({
    baseTiles,  // {dx,dy -> Uint8Array PNG | null}
    radarTiles, // {dx,dy -> Uint8Array PNG | null}
    centerPx: px,
    centerPy: py,
    out: DEVICE_TILE_SIZE,
    drawMarker: true,
  });

  const resp = new Response(png, {
    headers: {
      "Content-Type": "image/png",
      "X-Content-Type-Options": "nosniff",
      // Per-frame images are immutable: a given validtime never changes.
      "Cache-Control": "public, max-age=86400, immutable",
    },
  });
  ctx.waitUntil(cache.put(cacheKey, resp.clone()));
  return resp;
}

// Lazily-rendered, per-isolate cache of the fixed speed-test asset. The
// pattern is deterministic, so every isolate (and every deploy) serves
// byte-identical bytes.
let speedtestBytes = null;

/**
 * Serve the fixed-size synthetic PNG the speed-test widget times its
 * makeImageRequest path against. A real /tile frame varies in size with the
 * weather and location, so timings against it aren't comparable across runs;
 * this asset never changes (see composite.speedtestPNG). Immutable-cacheable:
 * intermediaries (Cloudflare, Garmin's image service) may cache it, which
 * mirrors how a warm real frame is served.
 */
function handleSpeedTest() {
  if (!speedtestBytes) speedtestBytes = speedtestPNG(DEVICE_TILE_SIZE);
  return new Response(speedtestBytes, {
    headers: {
      "Content-Type": "image/png",
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "public, max-age=86400, immutable",
    },
  });
}

/**
 * Which tile offsets (-1/0/1) a centred `out`-px window overlaps on one axis.
 * `center` is the rider's pixel within the centre tile (0..255). The window's
 * top-left in 3x3-grid coords is TILE+center-floor(out/2); a tile column/row c
 * (c in 0..2, offset c-1) is included iff the window intersects [c*TILE,
 * (c+1)*TILE). composite.js reads exactly these cells, so the dropped ones can't
 * affect the output.
 */
function windowTileOffsets(center, out) {
  const half = Math.floor(out / 2);
  const g0 = TILE + center - half;
  const g1 = g0 + out - 1;
  const offs = [];
  for (let c = 0; c <= 2; c++) {
    const lo = c * TILE;
    if (g0 <= lo + TILE - 1 && g1 >= lo) offs.push(c - 1);
  }
  return offs;
}

/** Fetch the requested tile offsets; out["dx,dy"] = PNG bytes | null. */
async function fetchNeighbourhood({ x, y, dxs, dys, urlFor, cacheTtl }) {
  const jobs = [];
  const out = {};
  for (const dx of dxs) {
    for (const dy of dys) {
      const u = urlFor(x + dx, y + dy);
      jobs.push(
        fetchTilePNG(u, cacheTtl).then((buf) => {
          out[`${dx},${dy}`] = buf; // null if 404 (no-rain / off-grid)
        })
      );
    }
  }
  await Promise.all(jobs);
  return out;
}

/** Fetch a single PNG tile. 404 => null (empty radar / off-grid base). */
async function fetchTilePNG(u, cacheTtl = 300) {
  const cache = caches.default;
  const key = new Request(u);
  const hit = await cache.match(key);
  if (hit) return new Uint8Array(await hit.arrayBuffer());

  let r;
  try {
    r = await fetch(u, {
      cf: { cacheTtl, cacheEverything: true },
      signal: AbortSignal.timeout(5000), // bound a stalled tile; one slow tile != a hung frame
    });
  } catch {
    // Network error or timeout (AbortError) - degrade gracefully rather than
    // blanking the whole frame. The compositor renders a null tile as background.
    return null;
  }
  // 404 is normal (empty radar / off-grid base). Any other non-OK status: same
  // graceful degradation as above.
  if (!r.ok) return null;
  const buf = new Uint8Array(await r.arrayBuffer());
  return buf;
}

// ---- small helpers ---------------------------------------------------------
/**
 * JSON response with the standard nosniff header.
 * @param {unknown} obj body to serialise
 * @param {number} [status] HTTP status (default 200)
 * @param {Record<string,string>} [extraHeaders] extra response headers
 * @returns {Response}
 */
function json(obj, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json",
      "X-Content-Type-Options": "nosniff",
      ...extraHeaders,
    },
  });
}
/** Parse + validate the rider geo params shared by /frames and /tile. */
function geoParams(url) {
  const lat = num(url, "lat");
  const lon = num(url, "lon");
  const z = clamp(int(url, "z", 10), Z_MIN, Z_MAX);
  if (lat < JAPAN.latMin || lat > JAPAN.latMax || lon < JAPAN.lonMin || lon > JAPAN.lonMax) {
    throw new HttpError(400, "out-of-range coordinates (Japan only)");
  }
  return { lat, lon, z };
}
/**
 * Required float query param. Throws HttpError(400) if absent or non-numeric.
 * @param {URL} url
 * @param {string} k param name
 * @returns {number}
 */
function num(url, k) {
  const v = parseFloat(url.searchParams.get(k) ?? "");
  if (Number.isNaN(v)) throw new HttpError(400, `bad/missing param: ${k}`);
  return v;
}
/**
 * Optional integer query param, falling back to a default when absent/invalid.
 * @param {URL} url
 * @param {string} k param name
 * @param {number} dflt default when the param is missing or not an integer
 * @returns {number}
 */
function int(url, k, dflt) {
  const raw = url.searchParams.get(k);
  if (raw == null) return dflt;
  const v = parseInt(raw, 10);
  return Number.isNaN(v) ? dflt : v;
}
/** A JMA basetime/validtime: exactly 14 digits (YYYYMMDDHHmmss). Strict, so the
 *  value can't inject path traversal / alternate paths into the upstream URL. */
function timestamp(url, k) {
  const v = url.searchParams.get(k);
  if (!v || !/^\d{14}$/.test(v)) throw new HttpError(400, `bad/missing param: ${k}`);
  return v;
}
/**
 * Clamp a number to the inclusive [lo, hi] range.
 * @param {number} v
 * @param {number} lo
 * @param {number} hi
 * @returns {number}
 */
function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}
/**
 * Round to 4 decimal places (~11 m of lat/lon; sub-pixel at every supported
 * zoom) so jittery fixes collapse onto one /tile URL and cache entry.
 * @param {number} v
 * @returns {number}
 */
function round4(v) {
  return Math.round(v * 1e4) / 1e4;
}

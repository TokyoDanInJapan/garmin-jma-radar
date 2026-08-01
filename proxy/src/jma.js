// @ts-check
/**
 * All JMA-specific URL construction lives here. These endpoints are the
 * UNDOCUMENTED internal endpoints that power the JMA website's nowcast viewer.
 * They are not an official API and may change without notice. When JMA breaks
 * something, this is the only file you should need to touch.
 *
 * Observed structure (verify before relying on it):
 *   targetTimes: https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N1.json
 *     -> array of { basetime, validtime, elements: [...] }
 *   radar tile:  https://www.jma.go.jp/bosai/jmatile/data/nowc/
 *                  {basetime}/none/{validtime}/surf/hrpns/{z}/{x}/{y}.png
 *
 * "hrpns" = 高解像度降水ナウキャスト (high-resolution precipitation nowcast).
 * Tiles are transparent PNGs (no-rain areas are transparent), designed to
 * overlay a GSI base map. 404 is normal for empty tiles.
 */

const JMA_BASE = "https://www.jma.go.jp/bosai/jmatile/data/nowc";
// N1 = observed/analysis frames (basetime===validtime).
// N2 = forecast frames (validtime>basetime), out to +60 min in 5-min steps.
const OBSERVED_URL = `${JMA_BASE}/targetTimes_N1.json`;
const FORECAST_URL = `${JMA_BASE}/targetTimes_N2.json`;

// Presentation window: 15 min of observed past through 60 min of forecast,
// sampled every 15 min. All offsets land on JMA's native 5-min grid, so each
// maps to a real frame. Note +35..+60 min forecast is 1 km resolution (coarser)
// vs 250 m for the rest – JMA's own limitation.
//
// FRAME_PRIORITY_MIN orders the offsets by *importance*, not by time. When the
// caller asks for fewer than the full set (the device's `frameCount` setting),
// we keep the first `count` of these and drop the rest, then play the kept ones
// back oldest-first: "now" is always shown, then the +60 forecast endpoint,
// then the intermediate steps fill in. MAX_FRAMES is the hard cap - 6 is the
// most the device can hold resident at full 288px without exhausting the widget
// memory budget (a 7th frame OOMs mid-load).
const FRAME_PRIORITY_MIN = [0, 60, 30, 45, 15, -15];
const MAX_FRAMES = FRAME_PRIORITY_MIN.length; // 6 - device memory ceiling

/**
 * Fetch one targetTimes file and normalise to [{basetime, validtime}].
 * `observedOnly` keeps analysis frames (basetime===validtime). Otherwise keeps
 * forecast frames (validtime>basetime). Edge-cached ~60s so we don't refetch
 * per device.
 */
async function fetchTimes(url, ctx, observedOnly) {
  const cache = caches.default;
  // Cache the *normalised* list under a synthetic key (same radar.invalid
  // pattern as handleTile's). A fragment ("url#cache") is not a safe
  // discriminator: the Cache API may strip it, which would collide this entry
  // with the raw upstream response cached by cf.cacheEverything.
  const key = new Request(`https://radar.invalid/targetTimes?u=${encodeURIComponent(url)}`);
  const hit = await cache.match(key);
  if (hit) return await hit.json();

  const r = await fetch(url, {
    cf: { cacheTtl: 60, cacheEverything: true },
    signal: AbortSignal.timeout(5000), // don't hang the request on a stalled origin
  });
  if (!r.ok) throw new Error(`targetTimes ${r.status}`);
  const raw = await r.json();
  // JMA occasionally serves an error object/HTML instead of the array. Guard so
  // a malformed upstream body surfaces as a clean error, not a TypeError.
  if (!Array.isArray(raw)) throw new Error("targetTimes: unexpected shape");

  const normalized = raw
    .filter((t) => t.basetime && t.validtime
      && (observedOnly ? t.basetime === t.validtime : t.validtime > t.basetime))
    .map((t) => ({ basetime: t.basetime, validtime: t.validtime }));

  // Some responses are newest-first. Sort oldest-first for playback.
  normalized.sort((a, b) => (a.validtime < b.validtime ? -1 : 1));

  const resp = new Response(JSON.stringify(normalized), {
    headers: { "Content-Type": "application/json", "Cache-Control": "max-age=60" },
  });
  ctx.waitUntil(cache.put(key, resp.clone()));
  return normalized;
}

/**
 * Assemble the -15 .. +60 min frame set (15-min steps). Past/now frames come
 * from observed (N1), forecast frames from N2. The two share an anchor because
 * N2's basetime is the latest analysis time (= newest observed frame). `count`
 * caps how many frames to return, chosen by FRAME_PRIORITY_MIN (now first, then
 * +60, ...) and clamped to [1, MAX_FRAMES]. Returns ordered
 * [{basetime, validtime, offset}] oldest-first (offset = minutes from the
 * analysis time), silently skipping any offset JMA doesn't currently have a
 * frame for.
 */
export async function getFrameTimes(env, ctx, count = MAX_FRAMES) {
  // Enforce the device memory ceiling regardless of what the client asks for. A
  // 0/NaN/negative count falls back to the full set.
  const want = Math.min(MAX_FRAMES, Math.max(1, Math.floor(count) || MAX_FRAMES));
  // The `want` highest-priority offsets, played back oldest-first.
  const offsets = FRAME_PRIORITY_MIN.slice(0, want).sort((a, b) => a - b);

  const [observed, forecast] = await Promise.all([
    fetchTimes(OBSERVED_URL, ctx, true),
    fetchTimes(FORECAST_URL, ctx, false),
  ]);

  // Anchor "now" on the forecast basetime (the latest analysis). Fall back to
  // the newest observed validtime if the forecast list is unavailable.
  const anchorStr = forecast.length ? forecast[0].basetime
    : observed.length ? observed[observed.length - 1].validtime
    : null;
  if (anchorStr == null) throw new Error("no target times available");
  const anchorMs = parseJmaTime(anchorStr);

  // Index by validtime so each offset is an O(1) lookup.
  const obsByValid = new Map(observed.map((t) => [t.validtime, t]));
  const fcByValid = new Map(forecast.map((t) => [t.validtime, t]));

  const out = [];
  for (const off of offsets) {
    const target = formatJmaTime(anchorMs + off * 60000);
    // <=0 is observed/analysis (basetime===validtime), and >0 is forecast.
    const t = off > 0 ? fcByValid.get(target) : obsByValid.get(target);
    if (t) out.push({ basetime: t.basetime, validtime: t.validtime, offset: off });
  }
  if (out.length === 0) throw new Error("no frames in target window");
  return out;
}

/**
 * Build the URL for one JMA hrpns radar tile (z/x/y slippy scheme) at a given
 * analysis/valid time pair.
 * @param {Object} args
 * @param {number} args.z zoom level
 * @param {number} args.x tile x
 * @param {number} args.y tile y
 * @param {string} args.basetime analysis time "YYYYMMDDHHmmss" (UTC)
 * @param {string} args.validtime valid time "YYYYMMDDHHmmss" (UTC)
 * @returns {string} fully-qualified radar tile URL
 */
export function radarTileURL({ z, x, y, basetime, validtime }) {
  return `${JMA_BASE}/${basetime}/none/${validtime}/surf/hrpns/${z}/${x}/${y}.png`;
}

/** "YYYYMMDDHHmmss" (UTC) -> epoch ms. */
export function parseJmaTime(s) {
  return Date.UTC(
    +s.slice(0, 4), +s.slice(4, 6) - 1, +s.slice(6, 8),
    +s.slice(8, 10), +s.slice(10, 12), +s.slice(12, 14) || 0
  );
}

/** epoch ms -> "YYYYMMDDHHmmss" (UTC). */
export function formatJmaTime(ms) {
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}`
    + `${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`;
}

/** "YYYYMMDDHHmmss" (UTC) -> "HH:MM" in JST (UTC+9). Hour wraps at midnight;
 *  this is a clock label, not a date, so the day rollover doesn't matter. */
export function jstLabel(validtime) {
  const hh = parseInt(validtime.slice(8, 10), 10);
  const mm = validtime.slice(10, 12);
  const jst = (hh + 9) % 24;
  return `${String(jst).padStart(2, "0")}:${mm}`;
}

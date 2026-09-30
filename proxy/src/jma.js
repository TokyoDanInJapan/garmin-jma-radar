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

import { targetTimes } from "./memo.js";

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

const MINUTE = 60 * 1000;
const STEP_MS = 5 * MINUTE;        // JMA's native frame grid
const MAX_LEAD_MS = 60 * MINUTE;   // hrpns forecasts run to +60 min
const MAX_AGE_MS = 3 * 60 * MINUTE; // older than any frame list a device can hold
const CLOCK_SKEW_MS = 5 * MINUTE;

/**
 * Fetch one targetTimes file and normalise to [{basetime, validtime}].
 * `observedOnly` keeps analysis frames (basetime===validtime). Otherwise keeps
 * forecast frames (validtime>basetime).
 *
 * Two cache layers, both short: the fetch is edge-cached for 30 s (shared by
 * every isolate in the colo), and the normalised list is kept in memory for
 * 30 s. There used to be a third, Cache API layer at 60 s on top of a 60 s
 * fetch cache, so a new JMA frame could take two minutes to appear.
 */
async function fetchTimes(url, observedOnly) {
  const hit = targetTimes.get(url);
  if (hit) return hit;

  const r = await fetch(url, {
    cf: { cacheTtl: 30, cacheEverything: true },
    signal: AbortSignal.timeout(5000), // don't hang the request on a stalled origin
  });
  if (!r.ok) throw new Error(`targetTimes ${r.status}`);
  const raw = await r.json();
  // JMA occasionally serves an error object/HTML instead of the array. Guard so
  // a malformed upstream body surfaces as a clean error, not a TypeError.
  if (!Array.isArray(raw)) throw new Error("targetTimes: unexpected shape");

  const normalized = raw
    .filter((t) => t && isJmaTime(t.basetime) && isJmaTime(t.validtime)
      && (observedOnly ? t.basetime === t.validtime : t.validtime > t.basetime))
    .map((t) => ({ basetime: t.basetime, validtime: t.validtime }));

  // Some responses are newest-first. Sort oldest-first for playback.
  normalized.sort((a, b) => (a.validtime < b.validtime ? -1 : 1));

  targetTimes.set(url, normalized);
  return normalized;
}

/** A well-formed "YYYYMMDDHHmmss" that names a real instant (no month 13). */
function isJmaTime(s) {
  return typeof s === "string" && /^\d{14}$/.test(s) && formatJmaTime(parseJmaTime(s)) === s;
}

/**
 * Whether a /tile basetime/validtime pair could be a real hrpns frame: both real
 * instants on the 5-minute grid, a lead of 0 to +60 min, and a basetime from the
 * last 3 hours (with a little clock skew). The regex in index.js already blocks
 * path injection. This stops a token holder from minting unlimited distinct
 * cache keys, each worth up to 18 upstream fetches, and from requesting a future
 * frame before JMA publishes it, which would cache as "no rain".
 * @param {string} basetime
 * @param {string} validtime
 * @param {number} nowMs
 * @returns {boolean}
 */
export function isPlausibleFrame(basetime, validtime, nowMs) {
  if (!isJmaTime(basetime) || !isJmaTime(validtime)) return false;
  const b = parseJmaTime(basetime);
  const lead = parseJmaTime(validtime) - b;
  const age = nowMs - b;
  return b % STEP_MS === 0 && lead % STEP_MS === 0
    && lead >= 0 && lead <= MAX_LEAD_MS
    && age >= -CLOCK_SKEW_MS && age <= MAX_AGE_MS;
}

/**
 * Assemble the -15 .. +60 min frame set (15-min steps). Past/now frames come
 * from observed (N1), forecast frames from N2. `count` caps how many frames to
 * return, clamped to [1, MAX_FRAMES]. Offsets are taken in FRAME_PRIORITY_MIN
 * order (now first, then +60, ...), skipping any JMA doesn't currently have and
 * moving on to the next, until `count` are found. Returns
 * [{basetime, validtime, offset}] oldest-first (offset = minutes from the
 * anchor analysis time).
 * @param {number} [count]
 * @returns {Promise<Array<{ basetime: string, validtime: string, offset: number }>>}
 */
export async function getFrameTimes(count = MAX_FRAMES) {
  // Enforce the device memory ceiling regardless of what the client asks for. A
  // 0/NaN/negative count falls back to the full set.
  const want = Math.min(MAX_FRAMES, Math.max(1, Math.floor(count) || MAX_FRAMES));

  const [observed, forecast] = await Promise.all([
    fetchTimes(OBSERVED_URL, true),
    fetchTimes(FORECAST_URL, false),
  ]);

  // N2 should hold one basetime, the latest analysis. If it ever holds more,
  // keep the newest run, so one frame set never mixes two forecasts.
  const fcBase = forecast.reduce((m, t) => (t.basetime > m ? t.basetime : m), "");
  const newestObs = observed.length ? observed[observed.length - 1].validtime : "";

  // Anchor "now" on the latest analysis BOTH lists have reached. The two files
  // are fetched and cached separately, so one can be a 5-min step ahead of the
  // other. Anchoring on N2 alone dropped "now" whenever N1 lagged, and a
  // count=1 request then failed with a 502.
  const anchors = [fcBase, newestObs].filter(Boolean).sort();
  if (anchors.length === 0) throw new Error("no target times available");
  const anchorMs = parseJmaTime(anchors[0]);

  // Index by validtime so each offset is an O(1) lookup.
  const obsByValid = new Map(observed.map((t) => [t.validtime, t]));
  const fcByValid = new Map(forecast.filter((t) => t.basetime === fcBase).map((t) => [t.validtime, t]));

  const out = [];
  for (const off of FRAME_PRIORITY_MIN) {
    if (out.length === want) break;
    const target = formatJmaTime(anchorMs + off * MINUTE);
    // <=0 is observed/analysis (basetime===validtime), and >0 is forecast.
    const t = off > 0 ? fcByValid.get(target) : obsByValid.get(target);
    if (t) out.push({ basetime: t.basetime, validtime: t.validtime, offset: off });
  }
  if (out.length === 0) throw new Error("no frames in target window");
  return out.sort((a, b) => a.offset - b.offset);
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

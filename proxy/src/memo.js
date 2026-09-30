// @ts-check
/**
 * Per-isolate, in-memory caches.
 *
 * The Cache API (caches.default) does nothing on a *.workers.dev deployment,
 * which is how the README deploys the Worker. Only a custom domain or route gets
 * a working edge cache. Without these, every /tile on workers.dev decodes 4-18
 * PNGs and re-encodes a frame, which puts the free plan's 10 ms CPU limit at
 * risk. An isolate serves many requests, so a small LRU here catches most
 * repeats: the 6 frames of one load share their base tiles, and a device that
 * reopens the widget asks for the same frames again. On a custom domain these
 * sit in front of the edge cache and save a cache round trip.
 *
 * Sizes are bounded so an isolate stays well inside the 128 MB Worker limit:
 * a frame is ~12 KB and a decoded tile is 256 KB.
 */

/**
 * A least-recently-used map with an optional time to live. Map keeps insertion
 * order, so re-inserting on every hit makes the first key the least recent.
 * @template V
 */
export class Lru {
  /**
   * @param {number} max entries kept before the least recent is dropped
   * @param {number} [ttlMs] entry lifetime (default: until evicted)
   */
  constructor(max, ttlMs = Infinity) {
    this.max = max;
    this.ttlMs = ttlMs;
    /** @type {Map<string, { v: V, exp: number }>} */
    this.map = new Map();
  }

  /**
   * @param {string} key
   * @returns {V | undefined} undefined on a miss or an expired entry
   */
  get(key) {
    const e = this.map.get(key);
    if (!e) return undefined;
    this.map.delete(key);
    if (e.exp <= Date.now()) return undefined;
    this.map.set(key, e);
    return e.v;
  }

  /**
   * @param {string} key
   * @param {V} v
   */
  set(key, v) {
    this.map.delete(key);
    this.map.set(key, { v, exp: Date.now() + this.ttlMs });
    if (this.map.size > this.max) {
      const oldest = this.map.keys().next().value;
      if (oldest !== undefined) this.map.delete(oldest);
    }
  }

  clear() {
    this.map.clear();
  }
}

/** Rendered /tile frames by canonical cache key. Immutable, so no TTL. */
export const frames = /** @type {Lru<Uint8Array>} */ (new Lru(64));

/**
 * Decoded GSI base-map tiles by URL, or null for a 404 (off-grid). Base tiles
 * change rarely, and one load of 6 frames uses the same 4-9 of them 6 times.
 */
export const baseTiles = /** @type {Lru<import("./composite.js").Decoded | null>} */ (
  new Lru(24, 24 * 3600 * 1000)
);

/**
 * Normalised JMA targetTimes lists by URL. JMA publishes every 5 minutes, and
 * the fetch below is also cached for 30 s at the edge, so a list is at most
 * about a minute behind.
 */
export const targetTimes = /** @type {Lru<Array<{ basetime: string, validtime: string }>>} */ (
  new Lru(4, 30 * 1000)
);

/** Empty every cache. For tests, which stub upstream responses per test. */
export function clearMemos() {
  frames.clear();
  baseTiles.clear();
  targetTimes.clear();
}

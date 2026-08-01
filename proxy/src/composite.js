// @ts-check
/**
 * Compositing: reproduce the JMA nowcast viewer's rendering, server-side.
 *
 *   1. For each output pixel, sample the GSI base map underneath it, desaturated
 *      to greyscale + lightened – the washed look the viewer applies so the
 *      coloured radar stands out.
 *   2. Alpha-composite the JMA radar on top at reduced opacity (radar pixels are
 *      fully opaque, and dimming lets the map show through).
 *   3. Optionally stamp a marker dot at the centre.
 *   4. Encode PNG.
 *
 * The window is rider-centred and may straddle tile boundaries, so we work over a
 * 3x3 tile neighbourhood ("dx,dy" -> PNG bytes | null). Rather than build the full
 * 768x768 canvas and crop it (most of which is thrown away), we iterate the
 * `out` x `out` OUTPUT pixels directly and sample the one source pixel each maps
 * to – ~30x fewer pixel ops at out=288, and we desaturate only visible base
 * pixels. Output is identical to the old crop-the-canvas approach.
 *
 * Pure JS (upng-js) so it runs unchanged in the Workers runtime and in Node (the
 * tests render frames directly). No Canvas / WASM needed. scripts/gen-samples.mjs
 * produces equivalent sample images with a separate standalone implementation.
 *
 * Licensing: the radar is JMA's (出典: 気象庁, processed). The base map is GSI's
 * (出典: 国土地理院). Both attributions belong in the device UI.
 */

import UPNG from "upng-js";

const TILE = 256;
const GRID = 3 * TILE; // 768
const BG = [235, 235, 235, 255]; // light grey where a base tile is missing/off-grid
const RADAR_OPACITY = 0.85;

// Posterize the grey GSI base-map ramp to this many levels before compositing.
// The base map's smooth grey gradient (roads, labels, contours) is the dominant
// source of PNG entropy. Snapping it to a handful of levels cuts the encoded size
// by ~60% with no meaningful loss (it's a faint, washed-out backdrop) and – just
// as importantly – frees palette slots so the radar's precip colours survive a
// small CNUM. The radar layer itself is NOT posterized, so its intensity scale
// stays intact. 6 levels is the sweet spot: flatter banding isn't visible at this
// size, and 6 greys + the off-grid BG leave ~9 of CNUM's 16 slots for rain.
const BASE_LEVELS = 6;
const BASE_QSTEP = 255 / (BASE_LEVELS - 1);

// Palette size for the indexed-PNG encode. The content is the posterized grey
// base (BASE_LEVELS greys + BG) plus JMA's precip scale, which fits comfortably
// in 16. Crucially, <=16 colours encode at 4-BIT depth (~0.5 byte/px on device)
// instead of 8-bit, ~halving the per-frame device memory – headroom against the
// 6-frame OOM ceiling – and roughly halving the bytes Garmin's image service
// must shuttle over BLE. Without posterizing the base first, 16 colours would
// crush the radar. With it, the precip blues are preserved (verified on a live
// rain frame). Do NOT use 0 ("lossless"): anti-aliased radar edges push the frame
// past 256 distinct colours, making UPNG fall back to truecolour – bigger output,
// heavier encode, blown memory budget. Keeping ps>0 guarantees an indexed PNG.
const CNUM = 16;

/** Decode a PNG (palette/grey/truecolour, with or without alpha) to RGBA. */
function decodeRGBA(bytes) {
  const img = UPNG.decode(bytes);
  const rgba = new Uint8Array(UPNG.toRGBA8(img)[0]);
  return { w: img.width, h: img.height, data: rgba };
}

/**
 * Decode a "dx,dy" -> PNG|null neighbourhood into a flat 3x3 array indexed by
 * cell = cy*3 + cx (cx,cy in 0..2, dx=cx-1, dy=cy-1). Missing/404 cells -> null.
 * Decoding once up front keeps the hot per-pixel loop free of string-key lookups
 * and repeated decodes.
 */
function decodeGrid(tiles) {
  const grid = new Array(9).fill(null);
  for (const dx of [-1, 0, 1]) {
    for (const dy of [-1, 0, 1]) {
      const bytes = tiles[`${dx},${dy}`];
      if (!bytes) continue; // 404 / no-rain / off-grid
      grid[(dy + 1) * 3 + (dx + 1)] = decodeRGBA(bytes);
    }
  }
  return grid;
}

/** Stamp a filled red dot (radius r) at (cx,cy) on an out x out RGBA buffer. */
function marker(dst, out, cx, cy, r = 4) {
  for (let dy = -r; dy <= r; dy++) {
    for (let dx = -r; dx <= r; dx++) {
      if (dx * dx + dy * dy > r * r) continue;
      const x = cx + dx;
      const y = cy + dy;
      if (x < 0 || y < 0 || x >= out || y >= out) continue;
      const i = (y * out + x) * 4;
      dst[i] = 255;
      dst[i + 1] = 0;
      dst[i + 2] = 0;
      dst[i + 3] = 255;
    }
  }
}

/**
 * @param {Object} args
 * @param {Object} args.baseTiles  "dx,dy" -> Uint8Array PNG | null (GSI base map)
 * @param {Object} args.radarTiles "dx,dy" -> Uint8Array PNG | null (JMA radar)
 * @param {number} args.centerPx   rider x within the centre tile (0..255)
 * @param {number} args.centerPy   rider y within the centre tile (0..255)
 * @param {number} args.out        output square size in px
 * @param {boolean} args.drawMarker
 * @returns {Promise<Uint8Array>} PNG bytes
 */
export async function composite({ baseTiles, radarTiles, centerPx, centerPy, out, drawMarker }) {
  const base = decodeGrid(baseTiles);
  const radar = decodeGrid(radarTiles);

  // Top-left of the output window in 3x3-grid coordinates (centre tile starts at
  // TILE). Same window the old code cropped from the full canvas.
  const half = Math.floor(out / 2);
  const gx0 = TILE + centerPx - half;
  const gy0 = TILE + centerPy - half;

  const dst = new Uint8Array(out * out * 4);
  for (let oy = 0; oy < out; oy++) {
    const gy = gy0 + oy;
    const inRowGrid = gy >= 0 && gy < GRID;
    const cy = (gy / TILE) | 0;
    const sy = gy - cy * TILE;
    for (let ox = 0; ox < out; ox++) {
      const gx = gx0 + ox;
      const di = (oy * out + ox) * 4;
      if (!inRowGrid || gx < 0 || gx >= GRID) {
        dst.set(BG, di); // off the rendered grid -> background
        continue;
      }
      const cx = (gx / TILE) | 0;
      const sx = gx - cx * TILE;
      const cell = cy * 3 + cx;

      // Base layer (desaturated + lightened), composited over the BG.
      let r = BG[0], g = BG[1], b = BG[2];
      const bt = base[cell];
      if (bt && sx < bt.w && sy < bt.h) {
        const si = (sy * bt.w + sx) * 4;
        const ba = bt.data[si + 3] / 255; // base opacity is 1
        if (ba > 0) {
          const lum = 0.3 * bt.data[si] + 0.59 * bt.data[si + 1] + 0.11 * bt.data[si + 2];
          // Grey (all channels equal), posterized to BASE_LEVELS to shrink the PNG
          // and keep the palette small. Only the base is snapped. Radar stays full.
          const v = Math.round(Math.round((lum * 0.7 + 255 * 0.3) / BASE_QSTEP) * BASE_QSTEP);
          const inv = 1 - ba;
          r = Math.round(v * ba + r * inv);
          g = Math.round(v * ba + g * inv);
          b = Math.round(v * ba + b * inv);
        }
      }

      // Radar layer at reduced opacity, composited over the base.
      const rt = radar[cell];
      if (rt && sx < rt.w && sy < rt.h) {
        const si = (sy * rt.w + sx) * 4;
        const ra = (rt.data[si + 3] / 255) * RADAR_OPACITY;
        if (ra > 0) {
          const inv = 1 - ra;
          r = Math.round(rt.data[si] * ra + r * inv);
          g = Math.round(rt.data[si + 1] * ra + g * inv);
          b = Math.round(rt.data[si + 2] * ra + b * inv);
        }
      }

      dst[di] = r;
      dst[di + 1] = g;
      dst[di + 2] = b;
      dst[di + 3] = 255;
    }
  }

  if (drawMarker) marker(dst, out, half, half);

  const png = UPNG.encode([dst.buffer], out, out, CNUM);
  return new Uint8Array(png);
}

/**
 * Deterministic synthetic frame for the /speedtest endpoint: byte-identical on
 * every call, and shaped like a real composited frame (same dimensions, same
 * CNUM-colour indexed encode, and a pattern tuned to land near a real frame's
 * ~12 KB) so a transfer timed against it is representative of a real tile pull
 * – but, unlike /tile, comparable across runs because the size never varies
 * with weather or location.
 * @param {number} out output square size in px (the device tile size)
 * @returns {Uint8Array} PNG bytes
 */
export function speedtestPNG(out) {
  const rgba = new Uint8Array(out * out * 4);
  for (let y = 0; y < out; y++) {
    for (let x = 0; x < out; x++) {
      const i = (y * out + x) * 4;
      // Concentric rings + diagonal bands + a coarse jitter: enough entropy
      // that the indexed encode compresses like a real map-plus-radar frame
      // instead of collapsing to a few hundred bytes of flat colour.
      const dx = x - out / 2;
      const dy = y - out / 2;
      const ring = Math.floor(Math.sqrt(dx * dx + dy * dy) / 6) % 6;
      const band = Math.floor((x + 2 * y) / 24) % 4;
      const jit = ((x * 7 + y * 13) >> 2) % 3;
      rgba[i] = 90 + ring * 25 + jit * 10;
      rgba[i + 1] = 120 + band * 30 + jit * 8;
      rgba[i + 2] = 230 - ring * 20;
      rgba[i + 3] = 255;
    }
  }
  return new Uint8Array(UPNG.encode([rgba.buffer], out, out, CNUM));
}

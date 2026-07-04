/**
 * Generate sample images via the JMA API that the proxy wraps.
 *
 * For a rider location it pulls the most recent observed nowcast frames and, per
 * frame, fetches the full 3x3 tile neighbourhood and stitches a rider-centered
 * composite. It's a standalone reference (separate pngjs implementation) for what
 * the Worker renders: production composite.js composites the same layers but emits
 * only the cropped device window - and the Worker fetches just the tiles that
 * window overlaps, not the whole 3x3 - whereas this script also saves the full
 * 768x768 stitch for visual inspection.
 *
 * Output (../../samples relative to this file):
 *   tiles/frameNN_dx_dy.png   raw JMA tiles (the proxy's inputs)
 *   composite_frameNN.png     768x768 stitched 3x3 with a centered no-rain bg
 *   centered_frameNN.png      288x288 rider-centered crop (the device payload)
 *   index.json                metadata for the run
 *
 * Run:  node proxy/scripts/gen-samples.mjs [lat] [lon] [z] [n]
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { PNG } from "/tmp/imgtools/node_modules/pngjs/lib/png.js";
import { lonLatToTileXY } from "../src/tilemath.js";
import { radarTileURL } from "../src/jma.js";

const TILE = 256;
const OUT = 288; // matches DEVICE_TILE_SIZE in index.js
const BG = [235, 235, 235, 255]; // light fallback bg where a base tile is missing/off-grid
const BASE_STYLE = "english"; // GSI english labels - what JMA's en_nowc viewer uses
const BASE_DESATURATE = true; // JMA's viewer renders the base grayscale so the radar pops
const RADAR_OPACITY = 0.85; // JMA radar pixels are fully opaque; dim slightly, matching the viewer
const here = dirname(fileURLToPath(import.meta.url));
const samplesDir = join(here, "..", "..", "samples");

const N1_URL =
  "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N1.json";
// Base map = GSI (地理院タイル) tiles, fetched from JMA's own mirror - the exact
// source the JMA nowcast viewer uses (its "slmcs" layer). Same z/x/y scheme as
// the radar. Content is GSI's, so its attribution (出典: 国土地理院) is required
// alongside JMA's even though we fetch from jma.go.jp.
const gsiTileURL = (z, x, y) =>
  `https://www.jma.go.jp/tile/gsi/${BASE_STYLE}/${z}/${x}/${y}.png`;

// Desaturate + lighten a base tile toward the washed grayscale the JMA viewer
// applies client-side, so the colored radar stands out on top.
function desaturate(png) {
  for (let i = 0; i < png.data.length; i += 4) {
    const g = 0.3 * png.data[i] + 0.59 * png.data[i + 1] + 0.11 * png.data[i + 2];
    const v = Math.round(g * 0.7 + 255 * 0.3);
    png.data[i] = png.data[i + 1] = png.data[i + 2] = v;
  }
  return png;
}

// tile (z/x/y) -> lon/lat of the tile's NW corner
function tileToLonLat(x, y, z) {
  const n = 2 ** z;
  const lon = (x / n) * 360 - 180;
  const lat = (Math.atan(Math.sinh(Math.PI * (1 - (2 * y) / n))) * 180) / Math.PI;
  return { lon, lat };
}

async function fetchPNG(url) {
  const r = await fetch(url);
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  const buf = Buffer.from(await r.arrayBuffer());
  return PNG.sync.read(buf); // normalizes palette/RGBA -> RGBA
}

// Find the rainiest z=8 tile near a starting area for the newest frame, so the
// samples actually contain precipitation rather than empty transparent tiles.
async function findRain(basetime, validtime) {
  let best = { bytes: 0 };
  for (let x = 214; x <= 232; x++) {
    for (let y = 96; y <= 110; y++) {
      const u = radarTileURL({ z: 8, x, y, basetime, validtime });
      const r = await fetch(u);
      if (r.status !== 200) continue;
      const b = (await r.arrayBuffer()).byteLength;
      if (b > best.bytes) best = { bytes: b, x, y };
    }
  }
  return best;
}

function blank(w, h, fill) {
  const png = new PNG({ width: w, height: h });
  for (let i = 0; i < png.data.length; i += 4) {
    png.data[i] = fill[0];
    png.data[i + 1] = fill[1];
    png.data[i + 2] = fill[2];
    png.data[i + 3] = fill[3];
  }
  return png;
}

// alpha-composite src (RGBA) onto dst at (ox,oy), scaling src alpha by `opacity`
function blit(dst, src, ox, oy, opacity = 1) {
  for (let sy = 0; sy < src.height; sy++) {
    const dy = oy + sy;
    if (dy < 0 || dy >= dst.height) continue;
    for (let sx = 0; sx < src.width; sx++) {
      const dx = ox + sx;
      if (dx < 0 || dx >= dst.width) continue;
      const si = (sy * src.width + sx) * 4;
      const a = (src.data[si + 3] / 255) * opacity;
      if (a === 0) continue;
      const di = (dy * dst.width + dx) * 4;
      for (let c = 0; c < 3; c++) {
        dst.data[di + c] = Math.round(src.data[si + c] * a + dst.data[di + c] * (1 - a));
      }
      dst.data[di + 3] = 255;
    }
  }
}

function crop(src, x, y, w, h) {
  const out = new PNG({ width: w, height: h });
  for (let oy = 0; oy < h; oy++) {
    for (let ox = 0; ox < w; ox++) {
      const sx = x + ox;
      const sy = y + oy;
      const di = (oy * w + ox) * 4;
      if (sx < 0 || sy < 0 || sx >= src.width || sy >= src.height) {
        out.data.set(BG, di);
        continue;
      }
      const si = (sy * src.width + sx) * 4;
      out.data.set(src.data.subarray(si, si + 4), di);
    }
  }
  return out;
}

function stampMarker(png, cx, cy) {
  const r = 4;
  for (let dy = -r; dy <= r; dy++) {
    for (let dx = -r; dx <= r; dx++) {
      if (dx * dx + dy * dy > r * r) continue;
      const x = cx + dx;
      const y = cy + dy;
      if (x < 0 || y < 0 || x >= png.width || y >= png.height) continue;
      const i = (y * png.width + x) * 4;
      png.data[i] = 255;
      png.data[i + 1] = 0;
      png.data[i + 2] = 0;
      png.data[i + 3] = 255;
    }
  }
}

const save = (name, png) => writeFileSync(join(samplesDir, name), PNG.sync.write(png));

async function main() {
  const z = Number(process.argv[4] ?? 10);
  const n = Number(process.argv[5] ?? 6);

  const times = (await (await fetch(N1_URL)).json())
    .filter((t) => t.basetime === t.validtime)
    .sort((a, b) => (a.validtime < b.validtime ? -1 : 1));
  const frames = times.slice(-n);
  const newest = frames[frames.length - 1];

  let lat = process.argv[2] ? Number(process.argv[2]) : null;
  let lon = process.argv[3] ? Number(process.argv[3]) : null;
  if (lat == null || lon == null) {
    const rain = await findRain(newest.basetime, newest.validtime);
    const c = tileToLonLat(rain.x + 0.5, rain.y + 0.5, 8);
    lat = c.lat;
    lon = c.lon;
    console.log(`auto-located rain: z8 tile ${rain.x},${rain.y} (${rain.bytes}B) -> lat ${lat.toFixed(4)} lon ${lon.toFixed(4)}`);
  }

  mkdirSync(join(samplesDir, "tiles"), { recursive: true });
  const { x, y, px, py } = lonLatToTileXY(lon, lat, z);
  const index = { generated: newest.validtime, rider: { lat, lon, z }, baseMap: `GSI ${BASE_STYLE}${BASE_DESATURATE ? " (desaturated)" : ""}`, radarOpacity: RADAR_OPACITY, centerTile: { x, y, px, py }, frames: [] };

  // Base map is identical across frames - fetch the 3x3 neighbourhood once.
  // Save the raw GSI tile (the proxy's input); composite with the desaturated copy.
  const base = {};
  for (const dx of [-1, 0, 1]) {
    for (const dy of [-1, 0, 1]) {
      const b = await fetchPNG(gsiTileURL(z, x + dx, y + dy));
      if (b) {
        save(`tiles/base_${dx}_${dy}.png`, b);
        if (BASE_DESATURATE) desaturate(b);
      }
      base[`${dx},${dy}`] = b;
    }
  }

  for (let fi = 0; fi < frames.length; fi++) {
    const f = frames[fi];
    const tag = String(fi).padStart(2, "0");
    const canvas = blank(3 * TILE, 3 * TILE, BG);
    let rainTiles = 0;
    for (const dx of [-1, 0, 1]) {
      for (const dy of [-1, 0, 1]) {
        // base map first (opaque), then radar on top at reduced opacity
        const b = base[`${dx},${dy}`];
        if (b) blit(canvas, b, (dx + 1) * TILE, (dy + 1) * TILE);
        const u = radarTileURL({ z, x: x + dx, y: y + dy, basetime: f.basetime, validtime: f.validtime });
        const tile = await fetchPNG(u);
        if (!tile) continue;
        save(`tiles/frame${tag}_${dx}_${dy}.png`, tile);
        // does it carry any non-transparent pixel?
        let painted = false;
        for (let i = 3; i < tile.data.length; i += 4) if (tile.data[i] !== 0) { painted = true; break; }
        if (painted) rainTiles++;
        blit(canvas, tile, (dx + 1) * TILE, (dy + 1) * TILE, RADAR_OPACITY);
      }
    }
    const cx = TILE + px;
    const cy = TILE + py;
    stampMarker(canvas, cx, cy);
    save(`composite_frame${tag}.png`, canvas);

    const centered = crop(canvas, cx - OUT / 2, cy - OUT / 2, OUT, OUT);
    stampMarker(centered, OUT / 2, OUT / 2);
    save(`centered_frame${tag}.png`, centered);

    index.frames.push({ i: fi, validtime: f.validtime, rainTiles });
    console.log(`frame ${tag} ${f.validtime}: ${rainTiles}/9 tiles with rain`);
  }

  writeFileSync(join(samplesDir, "index.json"), JSON.stringify(index, null, 2));
  console.log(`\nWrote ${frames.length} frames to ${samplesDir}`);
}

main().catch((e) => { console.error(e); process.exit(1); });

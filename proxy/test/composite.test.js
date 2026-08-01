import { test } from "node:test";
import assert from "node:assert/strict";
import UPNG from "upng-js";
import { composite } from "../src/composite.js";

const TILE = 256;

/** Build a solid-colour 256x256 RGBA tile encoded as PNG bytes. */
function solidTile([r, g, b, a]) {
  const buf = new Uint8Array(TILE * TILE * 4);
  for (let i = 0; i < buf.length; i += 4) {
    buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = a;
  }
  return new Uint8Array(UPNG.encode([buf.buffer], TILE, TILE, 0));
}

/** A 3x3 neighbourhood where every cell holds the same tile. */
function neighbourhood(tile) {
  const out = {};
  for (const dx of [-1, 0, 1]) for (const dy of [-1, 0, 1]) out[`${dx},${dy}`] = tile;
  return out;
}

function decode(png) {
  const img = UPNG.decode(png);
  return { w: img.width, h: img.height, rgba: new Uint8Array(UPNG.toRGBA8(img)[0]) };
}

test("composite emits a PNG of the requested output size", async () => {
  const base = neighbourhood(solidTile([100, 150, 200, 255]));
  const radar = neighbourhood(solidTile([0, 0, 255, 255]));
  const png = await composite({ baseTiles: base, radarTiles: radar, centerPx: 128, centerPy: 128, out: 288, drawMarker: false });
  const { w, h } = decode(png);
  assert.equal(w, 288);
  assert.equal(h, 288);
});

test("composite output is a small indexed-palette PNG (<=16 colours, <=4-bit)", async () => {
  // The encoder posterizes the base map and quantizes to <=16 colours so the
  // frame is a 4-bit indexed PNG – smaller over the wire and ~half the on-device
  // bytes/px. Guard it so a future encoder tweak can't silently regress to
  // truecolour or an 8-bit palette (which blows the device memory budget).
  const base = neighbourhood(solidTile([100, 150, 200, 255]));
  const radar = neighbourhood(solidTile([0, 0, 255, 255]));
  const png = await composite({ baseTiles: base, radarTiles: radar, centerPx: 128, centerPy: 128, out: 288, drawMarker: true });
  const img = UPNG.decode(png);
  assert.equal(img.ctype, 3, "indexed-colour PNG (not truecolour)");
  assert.ok(img.depth <= 4, `<=4-bit indexed depth (got ${img.depth})`);
  const colours = img.tabs && img.tabs.PLTE ? img.tabs.PLTE.length / 3 : 0;
  assert.ok(colours > 0 && colours <= 16, `<=16 palette colours (got ${colours})`);
});

test("null (404) tiles degrade to background, not a crash", async () => {
  const base = neighbourhood(null);   // every base tile missing
  const radar = neighbourhood(null);  // every radar tile missing
  const png = await composite({ baseTiles: base, radarTiles: radar, centerPx: 10, centerPy: 10, out: 64, drawMarker: false });
  const { w, h, rgba } = decode(png);
  assert.equal(w, 64);
  assert.equal(h, 64);
  // Top-left pixel should be the light-grey fallback (≈235), not transparent/black.
  assert.ok(rgba[0] > 200 && rgba[1] > 200 && rgba[2] > 200, "missing tiles render as light bg");
});

test("the rider marker is stamped red at the centre", async () => {
  const base = neighbourhood(solidTile([120, 120, 120, 255]));
  const radar = neighbourhood(null);
  const out = 64;
  const png = await composite({ baseTiles: base, radarTiles: radar, centerPx: 128, centerPy: 128, out, drawMarker: true });
  const { rgba } = decode(png);
  const c = (Math.floor(out / 2) * out + Math.floor(out / 2)) * 4;
  assert.ok(rgba[c] > 200 && rgba[c + 1] < 60 && rgba[c + 2] < 60, "centre pixel is red");
});

test("an output larger than the 3x3 grid fills the overflow with background", async () => {
  // out=800 > GRID(768), so the crop window runs off the canvas edges and those
  // pixels fall back to BG instead of reading out of bounds.
  const base = neighbourhood(solidTile([120, 120, 120, 255]));
  const radar = neighbourhood(null);
  const out = 800;
  const png = await composite({ baseTiles: base, radarTiles: radar, centerPx: 128, centerPy: 128, out, drawMarker: false });
  const { w, h, rgba } = decode(png);
  assert.equal(w, out);
  assert.equal(h, out);
  // Top-left corner is outside the rendered grid -> light-grey background.
  assert.ok(rgba[0] > 200 && rgba[1] > 200 && rgba[2] > 200, "overflow is background");
});

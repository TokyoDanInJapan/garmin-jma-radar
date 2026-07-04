import { test } from "node:test";
import assert from "node:assert/strict";
import { lonLatToTileXY } from "../src/tilemath.js";

test("z=0 puts the null island at the centre of the single world tile", () => {
  const { x, y, px, py } = lonLatToTileXY(0, 0, 0);
  assert.deepEqual({ x, y, px, py }, { x: 0, y: 0, px: 128, py: 128 });
});

test("z=1 quadrant boundaries land on the SE tile origin", () => {
  // lon 0 / lat 0 sit exactly on the seam between the four z=1 tiles.
  const { x, y, px, py } = lonLatToTileXY(0, 0, 1);
  assert.deepEqual({ x, y, px, py }, { x: 1, y: 1, px: 0, py: 0 });
});

test("pixel offsets are always within the tile", () => {
  for (const [lon, lat, z] of [
    [139.69, 35.69, 10], // Tokyo
    [135.5, 34.69, 12],  // Osaka
    [141.35, 43.06, 8],  // Sapporo
  ]) {
    const { x, y, px, py } = lonLatToTileXY(lon, lat, z);
    assert.ok(Number.isInteger(x) && Number.isInteger(y), "tile coords are integers");
    assert.ok(px >= 0 && px < 256, `px in range (${px})`);
    assert.ok(py >= 0 && py < 256, `py in range (${py})`);
  }
});

test("x grows eastward; y grows southward", () => {
  const a = lonLatToTileXY(135, 35, 10);
  const east = lonLatToTileXY(136, 35, 10);
  const south = lonLatToTileXY(135, 34, 10);
  assert.ok(east.x > a.x, "more easterly lon -> larger x");
  assert.ok(south.y > a.y, "more southerly lat -> larger y");
});

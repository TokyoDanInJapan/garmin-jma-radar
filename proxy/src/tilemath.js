// @ts-check
/**
 * Web Mercator (slippy map / XYZ) tile math.
 * JMA radar tiles use the standard z/x/y scheme (256px tiles), same as OSM/GSI.
 */

const TILE = 256;

/**
 * Convert lon/lat -> integer tile (x,y) at zoom z, plus the pixel position
 * (px,py) of the point WITHIN that tile (0..255). The pixel position lets the
 * proxy crop a window centered exactly on the rider rather than tile-aligned.
 */
export function lonLatToTileXY(lon, lat, z) {
  const n = Math.pow(2, z);
  const latRad = (lat * Math.PI) / 180;

  const xf = ((lon + 180) / 360) * n;
  const yf =
    ((1 -
      Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) /
      2) *
    n;

  const x = Math.floor(xf);
  const y = Math.floor(yf);
  const px = Math.floor((xf - x) * TILE);
  const py = Math.floor((yf - y) * TILE);

  return { x, y, px, py };
}

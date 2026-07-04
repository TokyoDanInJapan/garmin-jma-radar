// @ts-check
/**
 * Base-map tiles. The JMA nowcast viewer renders the radar over GSI (地理院)
 * tiles, served from JMA's own mirror - this is the viewer's "slmcs" layer.
 * Same z/x/y slippy-map scheme as the radar tiles.
 *
 * The base map's content is GSI's, so its attribution (出典: 国土地理院) is
 * required in the UI alongside JMA's, even though we fetch it from jma.go.jp.
 *
 * "english" carries English place labels (matches an English-language widget);
 * "pale" is the Japanese light style. The viewer desaturates the base to
 * grayscale client-side; we replicate that in composite.js so the radar pops.
 */

const GSI_MIRROR = "https://www.jma.go.jp/tile/gsi";

/**
 * Build the URL for one GSI base-map tile (z/x/y slippy scheme).
 * @param {Object} args
 * @param {number} args.z zoom level
 * @param {number} args.x tile x
 * @param {number} args.y tile y
 * @param {string} [args.style] tile style: "english" (default) or "pale"
 * @returns {string} fully-qualified tile URL on the JMA GSI mirror
 */
export function baseTileURL({ z, x, y, style = "english" }) {
  return `${GSI_MIRROR}/${style}/${z}/${x}/${y}.png`;
}

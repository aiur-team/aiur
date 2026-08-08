/**
 * JPEG quality knob for key images.
 *
 * The reference libraries disagree (python 100, node 95, Rust 90) and
 * streamdeck-ui#52 reports visible artefacts below 100 — so this is a real
 * payload-size / latency tradeoff, and the ticket requires it be configurable
 * with a justified default.
 *
 * ## Default: 90
 *
 * USB write throughput dominates: repaint cost is essentially the number of
 * 1KB reports, which is `ceil(jpegBytes / 1016)`. Lower quality means fewer
 * bytes, fewer reports, and a faster repaint of an 8-key panel that updates
 * constantly. At the Plus's small 120x120 key size, quality 90 is visually
 * close to 100 while cutting encoded size substantially, and it matches the
 * Rust `elgato-streamdeck` crate — the most recent multi-device reference. The
 * artefacts in streamdeck-ui#52 were reported on lower-resolution gen1/older
 * devices; 120x120 with mostly flat UI content (solid faces, short text, small
 * icons) tolerates 90 well. Users who see artefacts can raise it toward 100 at
 * the cost of more USB traffic.
 */

/** Justified default JPEG quality for key images. */
export const DEFAULT_JPEG_QUALITY = 90;

/** Inclusive lower bound for JPEG quality. */
export const MIN_JPEG_QUALITY = 1;

/** Inclusive upper bound for JPEG quality. */
export const MAX_JPEG_QUALITY = 100;

/**
 * Resolve a configured JPEG quality to a valid integer in
 * [{@link MIN_JPEG_QUALITY}, {@link MAX_JPEG_QUALITY}]. `undefined` yields
 * {@link DEFAULT_JPEG_QUALITY}. A non-integer or out-of-range value is a
 * configuration error and throws, rather than silently clamping to a quality
 * the operator did not choose.
 */
export function resolveJpegQuality(quality?: number): number {
  if (quality === undefined) return DEFAULT_JPEG_QUALITY;
  if (
    !Number.isInteger(quality) ||
    quality < MIN_JPEG_QUALITY ||
    quality > MAX_JPEG_QUALITY
  ) {
    throw new RangeError(
      `JPEG quality must be an integer in ${MIN_JPEG_QUALITY}..${MAX_JPEG_QUALITY}, got ${quality}`,
    );
  }
  return quality;
}

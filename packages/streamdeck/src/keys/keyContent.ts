/**
 * The unit of paint for a single key: either a solid RGB fill (cheap feature
 * report) or an encoded JPEG image (multi-report `0x07` upload). The renderer's
 * injected encoder produces one of these per key; the cache diffs them by
 * content identity and turns the changed ones into HID reports.
 *
 * Keeping fill-vs-image a first-class value (rather than always encoding a
 * JPEG) is what lets solid keys take the RGB fast path, and lets the cache
 * recognise "still solid black" as clean without hashing a bitmap.
 */
import { type RgbColor, buildKeyFillReport, type FillIndexBase } from "./keyFill.js";
import { buildKeyImageReports, type KeyReport } from "./keyImage.js";

export type KeyContent =
  | { readonly kind: "fill"; readonly color: RgbColor }
  | { readonly kind: "image"; readonly jpeg: Uint8Array };

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

/**
 * Content identity used for dirty tracking. Two fills are equal when their RGB
 * channels match; two images when their encoded bytes match. A fill and an
 * image are never equal. Encoding is assumed deterministic, so identical source
 * content yields identical bytes and is correctly treated as clean.
 */
export function contentEquals(a: KeyContent, b: KeyContent): boolean {
  if (a.kind === "fill" && b.kind === "fill") {
    return a.color.r === b.color.r && a.color.g === b.color.g && a.color.b === b.color.b;
  }
  if (a.kind === "image" && b.kind === "image") {
    return bytesEqual(a.jpeg, b.jpeg);
  }
  return false;
}

/** A stored, defensively-copied snapshot of a key's content for the cache. */
export function cloneContent(content: KeyContent): KeyContent {
  if (content.kind === "fill") {
    return { kind: "fill", color: { r: content.color.r, g: content.color.g, b: content.color.b } };
  }
  return { kind: "image", jpeg: Uint8Array.prototype.slice.call(content.jpeg) };
}

/**
 * Turn one key's content into its ordered HID reports: a single feature report
 * for a fill (under `base`), or the `0x07` chunk sequence for an image.
 */
export function buildContentReports(
  keyIndex: number,
  content: KeyContent,
  base: FillIndexBase,
): KeyReport[] {
  if (content.kind === "fill") {
    return [buildKeyFillReport(keyIndex, content.color, base)];
  }
  return buildKeyImageReports(keyIndex, content.jpeg);
}

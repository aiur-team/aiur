/**
 * Canvas rasteriser for key faces and touch-strip segments.
 *
 * This is the pixel end of the Stream Deck pipeline: it turns the pure
 * {@link KeyFace} / {@link SegmentContent} descriptions into the JPEGs the HID
 * writers upload. The parity target is `docs/design/streamdeck/` — the verbatim
 * Stream Deck slice of the Claude Design mock — and the bucket colours come
 * from the shared `key-face-contract.json` that the browser emulator also
 * reads, so the two surfaces cannot drift apart on state colour.
 *
 * Three things here are load-bearing and easy to regress:
 *
 * - **Gradients are painted, not assigned.** The contract's `face`/`glow` are
 *   CSS gradient strings. Assigning one to `fillStyle` is silently ignored by
 *   canvas and leaves the previous fill in place, which is what rendered every
 *   key solid black. They go through {@link createPaint}.
 * - **Progress states do not introduce a second segment.** Measured progress
 *   uses one green fill, unknown uses flat grey, and stale uses alpha only.
 * - **Titles re-wrap with real glyph metrics** rather than the character-count
 *   heuristic the pure layer uses, which is what lets a 120px key fit three
 *   proportional lines.
 */
import { createCanvas, type Canvas } from "@napi-rs/canvas";
import { composeKeyFace } from "./keys/keyFace.js";
import type { KeyDescriptor } from "./keys.js";
import type { SegmentContent } from "./touchStrip/stripLayout.js";
import { KEY_IMAGE_SIZE } from "./keys/keyImage.js";
import { SEGMENT_WIDTH, STRIP_HEIGHT as SEGMENT_HEIGHT } from "./touchStrip/geometry.js";
import { drawSegmentContent } from "./art/segments.js";
import { drawKey } from "./key-face.js";

export { wrapToWidth } from "./key-face.js";

export interface RasterizerOptions {
  readonly jpegQuality?: number;
}

const quality = (value: number | undefined): number => Math.max(1, Math.min(100, Math.trunc(value ?? 90)));

const drawSegment = (canvas: Canvas, content: SegmentContent, width: number): void => {
  drawSegmentContent(canvas.getContext("2d"), content, width);
};

/**
 * Cap on the encoded-image cache.
 *
 * The cache is keyed by content, and the strip's content is now unbounded: a
 * full-width chat readout is a different image for every scroll position of
 * every agent's transcript, at 800x100 rather than 200x100. Left uncapped, a
 * long-running sidecar accumulates one JPEG per distinct window it has ever
 * shown. Least-recently-used eviction keeps the working set — the current
 * mode's panels and the visible keys — resident, which is where every hit
 * comes from anyway.
 */
const IMAGE_CACHE_LIMIT = 512;

export const createRasterizer = (options: RasterizerOptions = {}) => {
  const jpegQuality = quality(options.jpegQuality);
  const cache = new Map<string, Uint8Array>();
  const encode = (canvas: Canvas): Uint8Array => Uint8Array.from(canvas.toBuffer("image/jpeg", jpegQuality));

  /** Cached bytes, promoted to most-recently-used, or undefined on a miss. */
  const recall = (cacheKey: string): Uint8Array | undefined => {
    const cached = cache.get(cacheKey);
    if (cached === undefined) return undefined;
    cache.delete(cacheKey);
    cache.set(cacheKey, cached);
    return cached;
  };

  const remember = (cacheKey: string, encoded: Uint8Array): Uint8Array => {
    cache.set(cacheKey, encoded);
    // Map iteration is insertion-ordered and `recall` re-inserts on a hit, so
    // the first key is the least recently used.
    while (cache.size > IMAGE_CACHE_LIMIT) cache.delete(cache.keys().next().value as string);
    return encoded;
  };

  return {
    key: (descriptor: KeyDescriptor): Uint8Array => {
      const cacheKey = `key:${JSON.stringify(descriptor)}`;
      const cached = recall(cacheKey);
      if (cached !== undefined) return cached.slice();
      const canvas = createCanvas(KEY_IMAGE_SIZE, KEY_IMAGE_SIZE);
      drawKey(canvas, composeKeyFace(descriptor));
      return remember(cacheKey, encode(canvas)).slice();
    },
    /**
     * Encodes one strip panel. `width` is the panel's own width — 200 for a
     * grid-mode segment, 400 for the merged provider area, 800 for the cmd and
     * logs readouts — and is part of the cache key, because the same content at
     * a different width is a different image.
     */
    segment: (content: SegmentContent, width: number = SEGMENT_WIDTH): Uint8Array => {
      // The chat readout is deliberately not cached.
      //
      // Its content changes every frame while a message is being revealed, so
      // every lookup is a guaranteed miss followed by an insert. Left in the
      // shared LRU, one reveal evicts every cached key face and leaves the map
      // full of 800x100 JPEGs that can never be hit again — the cache did not
      // merely fail to help, it actively threw away the entries that were
      // working.
      if (content.kind === "chatLog") {
        const canvas = createCanvas(width, SEGMENT_HEIGHT);
        drawSegment(canvas, content, width);
        return encode(canvas);
      }
      // The minute is part of the identity. A panel's content can be unchanged
      // while the pixels are not: `resetLabel` and `ageLabel` render relative
      // times off `Date.now()`, so a cache keyed on content alone would freeze
      // "3m" on the strip while the event key beside it ticked to "31m", and an
      // eviction would silently re-encode the same content into different
      // bytes — which is exactly what `StripRenderer` promises never happens.
      // Both labels are minute-resolution, so a minute bucket is the finest
      // grain that can change anything.
      const cacheKey = `segment:${width}:${Math.floor(Date.now() / 60_000)}:${JSON.stringify(content)}`;
      const cached = recall(cacheKey);
      if (cached !== undefined) return cached.slice();
      const canvas = createCanvas(width, SEGMENT_HEIGHT);
      drawSegment(canvas, content, width);
      return remember(cacheKey, encode(canvas)).slice();
    },
  };
};

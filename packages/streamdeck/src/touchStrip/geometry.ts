/**
 * Touch-strip segment geometry — a PROJECT DECISION, not a hardware spec.
 *
 * The Stream Deck + touch strip is 800x100 px. Neither the device, Elgato's
 * docs, nor any reference library defines a per-dial x-offset grid: node models
 * the strip as a single control spanning four columns. We therefore CHOOSE to
 * partition the strip into four independent 200-wide segments at x =
 * 0/200/400/600. This even split is arithmetic, not a documented spec.
 *
 * Each segment is uploaded with its own `0x0C` partial-region write (see
 * `imageWriter/headerGenerator.ts`) so a single segment — e.g. a provider usage
 * meter tick — can repaint without touching the other three. That independence
 * is the reason the strip is modelled as four regions rather than one.
 *
 * Segment roles by mode are defined by the renderer; the geometry here is mode
 * independent.
 */
import type { Region } from "../imageWriter/headerGenerator.js";

/** Full touch-strip dimensions in pixels. */
export const STRIP_WIDTH = 800;
export const STRIP_HEIGHT = 100;

/** Number of independent segments the strip is partitioned into. */
export const SEGMENT_COUNT = 4;

/** Width of each even-split segment in pixels. */
export const SEGMENT_WIDTH = STRIP_WIDTH / SEGMENT_COUNT; // 200

/** Stable index for each segment, left to right. */
export enum SegmentIndex {
  First = 0,
  Second = 1,
  Third = 2,
  Fourth = 3,
}

/**
 * The four project-owned segment rectangles, left to right. Each is a full-
 * height 200x100 column. Immutable and shared; callers must not mutate — both
 * the array and every region object are frozen, so `segmentRegion(i).x = 5`
 * fails loudly (in strict mode) rather than silently corrupting the shared
 * global.
 */
export const SEGMENT_REGIONS: readonly Region[] = Object.freeze([
  Object.freeze({ x: 0, y: 0, width: SEGMENT_WIDTH, height: STRIP_HEIGHT }),
  Object.freeze({ x: SEGMENT_WIDTH, y: 0, width: SEGMENT_WIDTH, height: STRIP_HEIGHT }),
  Object.freeze({ x: SEGMENT_WIDTH * 2, y: 0, width: SEGMENT_WIDTH, height: STRIP_HEIGHT }),
  Object.freeze({ x: SEGMENT_WIDTH * 3, y: 0, width: SEGMENT_WIDTH, height: STRIP_HEIGHT }),
]);

/** Region for a given segment index. Throws on an out-of-range index. */
export function segmentRegion(index: SegmentIndex): Region {
  if (!Number.isInteger(index) || index < 0 || index >= SEGMENT_COUNT) {
    throw new RangeError(`segment index out of range: ${String(index)}`);
  }
  return SEGMENT_REGIONS[index];
}

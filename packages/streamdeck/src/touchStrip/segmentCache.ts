/**
 * Encoded-segment cache with per-segment dirty tracking.
 *
 * The four touch-strip segments (see `geometry.ts`) each own an independent
 * `0x0C` partial-region write. This cache holds the last JPEG encoded for each
 * segment and only emits reports for segments whose encoded bytes actually
 * changed. That is the mechanism behind two touch-strip guarantees:
 *
 *   - a usage-meter tick that changes one segment repaints ONLY that segment;
 *   - re-submitting identical content for a segment produces no writes at all.
 *
 * The cache is transport-independent: it turns changed segment JPEGs into the
 * ordered report sequences the device transport (#1354) will later serialize
 * onto the hidraw handle. It never performs I/O and holds no device handle.
 *
 * Content identity is byte equality of the encoded JPEG. Encoding is expected
 * to be deterministic, so identical segment content yields identical bytes and
 * is correctly treated as clean. Callers that need to force a repaint (e.g.
 * after a device reset drops the on-screen image) call {@link invalidate}.
 */
import { buildRegionReports } from "../imageWriter/headerGenerator.js";
import { SEGMENT_COUNT, SegmentIndex, segmentRegion } from "./geometry.js";

/** A pending repaint of a single segment: its index and ordered HID reports. */
export interface SegmentPaint {
  readonly index: SegmentIndex;
  readonly reports: Buffer[];
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function assertSegmentIndex(index: number): void {
  if (!Number.isInteger(index) || index < 0 || index >= SEGMENT_COUNT) {
    throw new RangeError(
      `segment index must be an integer in 0..${SEGMENT_COUNT - 1}, got ${index}`,
    );
  }
}

export class SegmentCache {
  /** Last encoded JPEG per segment; `undefined` means never painted. */
  private readonly encoded: (Uint8Array | undefined)[] = new Array<
    Uint8Array | undefined
  >(SEGMENT_COUNT).fill(undefined);

  /** True when the segment's encoded content differs from the cached copy. */
  isDirty(index: SegmentIndex, jpeg: Uint8Array): boolean {
    assertSegmentIndex(index);
    const current = this.encoded[index];
    return current === undefined || !bytesEqual(current, jpeg);
  }

  /**
   * Offer new content for one segment. If it differs from the cached copy,
   * store it and return the ordered reports for its region; otherwise return
   * `null` and leave the cache untouched — the segment is not repainted.
   */
  paint(index: SegmentIndex, jpeg: Uint8Array): Buffer[] | null {
    assertSegmentIndex(index);
    if (!this.isDirty(index, jpeg)) return null;
    // Defensive copy so a later mutation of the caller's buffer cannot silently
    // desync the cached identity from what was actually written.
    this.encoded[index] = Uint8Array.prototype.slice.call(jpeg);
    return buildRegionReports(segmentRegion(index), jpeg);
  }

  /**
   * Offer content for several segments at once and return paints only for the
   * ones that changed, in ascending segment order. Segments absent from `next`
   * are left as-is. This is the strip-repaint entry point: a full-strip render
   * passes all four, and only the dirty ones produce writes.
   */
  paintAll(next: ReadonlyMap<SegmentIndex, Uint8Array>): SegmentPaint[] {
    const paints: SegmentPaint[] = [];
    for (let index = 0 as SegmentIndex; index < SEGMENT_COUNT; index += 1) {
      const jpeg = next.get(index);
      if (jpeg === undefined) continue;
      const reports = this.paint(index, jpeg);
      if (reports !== null) paints.push({ index, reports });
    }
    return paints;
  }

  /**
   * Drop the cached content for one segment (or all segments when `index` is
   * omitted) so the next {@link paint} for it repaints unconditionally. Use
   * after a device reset/suspend that clears the on-screen image.
   */
  invalidate(index?: SegmentIndex): void {
    if (index === undefined) {
      this.encoded.fill(undefined);
      return;
    }
    assertSegmentIndex(index);
    this.encoded[index] = undefined;
  }
}

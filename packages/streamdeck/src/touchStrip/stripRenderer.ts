/**
 * Touch-strip renderer — composes a mode into four segment contents, encodes
 * each to a JPEG, and diffs through the {@link SegmentCache} so only changed
 * segments produce `0x0C` region writes.
 *
 * This is the integrating layer over the pure pieces: `stripLayout` decides
 * what each segment shows, `SegmentCache` decides which changed, and
 * `headerGenerator` (via the cache) encodes the region writes. It stays
 * transport- and pixel-independent by taking the segment encoder as a
 * dependency: a canvas/JPEG encoder (device path, #1354/#1355) or OpenDeck's
 * layout system (#1342) supplies it. The renderer never performs I/O.
 *
 * The four regions are independent by construction: each segment is encoded and
 * diffed on its own, so re-rendering a mode whose data changed in one segment
 * (a provider-usage tick, one new chat line) yields exactly one `SegmentPaint`
 * and never repaints the other three — provided the encoder is deterministic
 * for unchanged content, which the cache's byte-identity diff assumes.
 */
import { SEGMENT_COUNT, SegmentIndex } from "./geometry.js";
import { SegmentCache, type SegmentPaint } from "./segmentCache.js";
import { composeStrip, type SegmentContent, type StripData } from "./stripLayout.js";

/**
 * Encodes one segment's structured content to a JPEG covering its 200x100
 * region. Must be deterministic: identical `content` must yield identical
 * bytes, or the cache cannot recognise an unchanged segment as clean.
 */
export type SegmentEncoder = (content: SegmentContent, index: SegmentIndex) => Uint8Array;

export class StripRenderer {
  constructor(
    private readonly encode: SegmentEncoder,
    private readonly cache: SegmentCache = new SegmentCache(),
  ) {}

  /**
   * Compose `input` into four segments, encode each, and return the region
   * writes for only the segments whose encoded bytes changed since the last
   * render — in ascending segment order. A first render returns all four; a
   * re-render with one changed segment returns exactly one.
   */
  render(input: StripData): SegmentPaint[] {
    const contents = composeStrip(input);
    const next = new Map<SegmentIndex, Uint8Array>();
    for (let index = 0 as SegmentIndex; index < SEGMENT_COUNT; index += 1) {
      next.set(index, this.encode(contents[index], index));
    }
    return this.cache.paintAll(next);
  }

  /**
   * Drop cached content for one segment (or all) so its next render repaints
   * unconditionally — e.g. after a device reset clears the on-screen image.
   */
  invalidate(index?: SegmentIndex): void {
    this.cache.invalidate(index);
  }
}

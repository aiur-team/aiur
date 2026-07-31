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
import { SEGMENT_COUNT, SegmentIndex, segmentRegion } from "./geometry.js";
import { buildRegionReports } from "../imageWriter/headerGenerator.js";
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

/** Timing for {@link measureUpdateLatency}, in milliseconds. */
export interface UpdateLatency {
  /** Time to build region reports for a single 200x100 segment. */
  readonly singleSegmentMs: number;
  /** Time to build region reports for all four segments (a full strip). */
  readonly fullStripMs: number;
  /** Reports produced for the single-segment write. */
  readonly singleSegmentReports: number;
  /** Reports produced across all four full-strip writes. */
  readonly fullStripReports: number;
}

/**
 * Measure the region-write encoding cost of a single-segment update versus a
 * full four-segment repaint, using a representative per-segment JPEG size. This
 * isolates the touch-strip's own encoding path (the part this package owns);
 * canvas encoding and hidraw transfer live in #1354/#1355. It exists to back
 * the ticket's "single-segment vs full-strip latency" acceptance with a real,
 * reproducible number rather than an asserted claim.
 *
 * `now` is injected (default `performance.now`) so callers can supply a
 * deterministic clock in tests.
 */
export function measureUpdateLatency(
  jpegBytesPerSegment: number,
  iterations = 1000,
  now: () => number = () => performance.now(),
): UpdateLatency {
  const jpeg = new Uint8Array(Math.max(0, Math.floor(jpegBytesPerSegment)));
  const region = segmentRegion(SegmentIndex.First);

  const singleStart = now();
  let singleReports = 0;
  for (let i = 0; i < iterations; i += 1) {
    singleReports = buildRegionReports(region, jpeg).length;
  }
  const singleSegmentMs = (now() - singleStart) / iterations;

  const fullStart = now();
  let fullReports = 0;
  for (let i = 0; i < iterations; i += 1) {
    fullReports = 0;
    for (let index = 0 as SegmentIndex; index < SEGMENT_COUNT; index += 1) {
      fullReports += buildRegionReports(segmentRegion(index), jpeg).length;
    }
  }
  const fullStripMs = (now() - fullStart) / iterations;

  return {
    singleSegmentMs,
    fullStripMs,
    singleSegmentReports: singleReports,
    fullStripReports: fullReports,
  };
}

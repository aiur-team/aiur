/**
 * Region-write latency measurement — an internal benchmark harness, deliberately
 * NOT part of the package's public surface (`index.ts` does not re-export it).
 *
 * It isolates the touch-strip's own region-write encoding path — the part this
 * package owns — and compares a single-segment update against a full
 * four-segment repaint. Canvas encoding and hidraw transfer live in #1354/#1355
 * and are additive on top. It exists to back the ticket's "single-segment vs
 * full-strip latency" acceptance with a real, reproducible number rather than an
 * asserted claim, and to let CI re-measure the regression later.
 *
 * Scope caveat: this measures REPORT-ENCODING COST ONLY. The full-strip figure
 * is four times the single-segment figure by construction (the same work looped
 * four times), so the ~4x ratio is arithmetic, not an empirical strip finding.
 * The real single-vs-full win is fewer USB transfers — 8 reports for one 200x100
 * segment vs 32 for the whole strip — which only becomes measurable once the
 * hidraw transport (#1354) lands. Re-measure end-to-end there.
 */
import { buildRegionReports } from "../imageWriter/headerGenerator.js";
import { SEGMENT_COUNT, SegmentIndex, segmentRegion } from "./geometry.js";

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
 * full four-segment repaint, using a representative per-segment JPEG size.
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

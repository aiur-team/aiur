import { describe, expect, it } from "vitest";

import { measureUpdateLatency } from "../../src/touchStrip/regionLatency.js";

describe("measureUpdateLatency", () => {
  it("reports timings and report counts for single vs full-strip writes", () => {
    // Deterministic monotonic clock so the assertion is stable.
    let t = 0;
    const clock = () => (t += 1);
    const result = measureUpdateLatency(20_000, 4, clock);

    expect(result.singleSegmentReports).toBeGreaterThan(0);
    // A full strip is four segments, so ~4x the single-segment report count.
    expect(result.fullStripReports).toBe(result.singleSegmentReports * 4);
    expect(result.singleSegmentMs).toBeGreaterThan(0);
    expect(result.fullStripMs).toBeGreaterThan(0);
  });

  it("runs against the real clock by default", () => {
    const result = measureUpdateLatency(20_000, 2);
    expect(result.singleSegmentReports).toBeGreaterThan(0);
    expect(result.fullStripReports).toBe(result.singleSegmentReports * 4);
    expect(result.singleSegmentMs).toBeGreaterThanOrEqual(0);
    expect(result.fullStripMs).toBeGreaterThanOrEqual(0);
  });

  it("clamps a negative byte count to an empty single terminating report", () => {
    const result = measureUpdateLatency(-5, 1, () => 0);
    expect(result.singleSegmentReports).toBe(1);
    expect(result.fullStripReports).toBe(4);
  });
});

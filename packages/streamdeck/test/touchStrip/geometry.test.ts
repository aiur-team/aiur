import { describe, expect, it } from "vitest";

import { buildRegionReports } from "../../src/imageWriter/headerGenerator.js";
import {
  SEGMENT_COUNT,
  SEGMENT_REGIONS,
  SEGMENT_WIDTH,
  SegmentIndex,
  STRIP_HEIGHT,
  STRIP_WIDTH,
  segmentRegion,
} from "../../src/touchStrip/geometry.js";

describe("touch-strip segment geometry", () => {
  it("partitions the 800x100 strip into four even 200-wide columns", () => {
    expect(STRIP_WIDTH).toBe(800);
    expect(STRIP_HEIGHT).toBe(100);
    expect(SEGMENT_COUNT).toBe(4);
    expect(SEGMENT_WIDTH).toBe(200);
    expect(SEGMENT_REGIONS.map((r) => r.x)).toEqual([0, 200, 400, 600]);
    for (const r of SEGMENT_REGIONS) {
      expect(r).toMatchObject({ y: 0, width: 200, height: 100 });
    }
  });

  it("covers the strip with no gaps or overlaps", () => {
    const sorted = [...SEGMENT_REGIONS].sort((a, b) => a.x - b.x);
    expect(sorted[0].x).toBe(0);
    for (let i = 1; i < sorted.length; i += 1) {
      expect(sorted[i].x).toBe(sorted[i - 1].x + sorted[i - 1].width);
    }
    const last = sorted[sorted.length - 1];
    expect(last.x + last.width).toBe(STRIP_WIDTH);
  });

  it("addresses each segment independently: a per-segment write never touches another column", () => {
    // Updating one segment produces reports scoped to exactly that region's x
    // span, so repainting one segment cannot repaint the others.
    for (let i = 0; i < SEGMENT_COUNT; i += 1) {
      const region = segmentRegion(i as SegmentIndex);
      const reports = buildRegionReports(region, new Uint8Array(4));
      for (const report of reports) {
        expect(report.readUInt16LE(2)).toBe(region.x);
        expect(report.readUInt16LE(6)).toBe(SEGMENT_WIDTH);
      }
      // No other segment shares this x offset.
      const others = SEGMENT_REGIONS.filter((_, j) => j !== i);
      expect(others.every((o) => o.x !== region.x)).toBe(true);
    }
  });

  it("exposes a frozen, immutable region table down to each region object", () => {
    expect(Object.isFrozen(SEGMENT_REGIONS)).toBe(true);
    for (const r of SEGMENT_REGIONS) {
      expect(Object.isFrozen(r)).toBe(true);
    }
  });

  it("rejects an out-of-range segment index", () => {
    expect(() => segmentRegion(-1 as SegmentIndex)).toThrow(RangeError);
    expect(() => segmentRegion(SEGMENT_COUNT as SegmentIndex)).toThrow(RangeError);
  });
});

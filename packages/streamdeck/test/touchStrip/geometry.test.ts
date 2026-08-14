import { describe, expect, it } from "vitest";

import { buildRegionReports } from "../../src/imageWriter/headerGenerator.js";
import {
  ENCODER_COUNT,
  encoderCenterX,
  SEGMENT_COUNT,
  SEGMENT_REGIONS,
  SEGMENT_WIDTH,
  SegmentIndex,
  STRIP_HEIGHT,
  STRIP_REGION,
  STRIP_WIDTH,
  segmentRegion,
  spanRegion,
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

  it("covers the whole strip as one region", () => {
    expect(STRIP_REGION).toEqual({ x: 0, y: 0, width: STRIP_WIDTH, height: STRIP_HEIGHT });
    expect(Object.isFrozen(STRIP_REGION)).toBe(true);
  });

  it("spans consecutive segments as one rectangle", () => {
    expect(spanRegion(SegmentIndex.Second, 2)).toEqual({ x: 200, y: 0, width: 400, height: STRIP_HEIGHT });
    expect(spanRegion(SegmentIndex.First, SEGMENT_COUNT)).toEqual({ x: 0, y: 0, width: STRIP_WIDTH, height: STRIP_HEIGHT });
    expect(Object.isFrozen(spanRegion(SegmentIndex.First, 1))).toBe(true);
  });

  // A label naming a knob has to sit over that knob. Only knob 1's band starts
  // at the strip's left edge, so the centres are quarter marks, not multiples.
  it("centres each encoder's band on its own quarter of the strip", () => {
    expect([0, 1, 2, 3].map(encoderCenterX)).toEqual([100, 300, 500, 700]);
    // Each centre sits inside its own quarter and no other.
    for (let index = 0; index < ENCODER_COUNT; index += 1) {
      const band = (STRIP_WIDTH / ENCODER_COUNT) * index;
      expect(encoderCenterX(index)).toBeGreaterThan(band);
      expect(encoderCenterX(index)).toBeLessThan(band + STRIP_WIDTH / ENCODER_COUNT);
    }
  });

  it("rejects an out-of-range encoder index", () => {
    expect(() => encoderCenterX(-1)).toThrow(RangeError);
    expect(() => encoderCenterX(ENCODER_COUNT)).toThrow(RangeError);
    expect(() => encoderCenterX(1.5)).toThrow(RangeError);
  });

  // A span that ran off the strip would silently paint the wrong pixels, which
  // is far harder to notice than a thrown layout bug.
  it("rejects a span that is not a positive integer or runs off the strip", () => {
    expect(() => spanRegion(SegmentIndex.First, 0)).toThrow(RangeError);
    expect(() => spanRegion(SegmentIndex.First, 1.5)).toThrow(RangeError);
    expect(() => spanRegion(SegmentIndex.Third, 3)).toThrow(RangeError);
    expect(() => spanRegion(-1 as SegmentIndex, 1)).toThrow(RangeError);
  });
});

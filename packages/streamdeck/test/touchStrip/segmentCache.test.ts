import { describe, expect, it } from "vitest";

import {
  SEGMENT_REGIONS,
  SegmentIndex,
} from "../../src/touchStrip/geometry.js";
import { SegmentCache } from "../../src/touchStrip/segmentCache.js";

const jpeg = (...bytes: number[]): Uint8Array => new Uint8Array(bytes);

describe("SegmentCache dirty tracking", () => {
  it("paints a segment the first time it is offered content", () => {
    const cache = new SegmentCache();
    expect(cache.isDirty(SegmentIndex.First, jpeg(1, 2, 3))).toBe(true);
    const reports = cache.paint(SegmentIndex.First, jpeg(1, 2, 3));
    expect(reports).not.toBeNull();
    // Reports carry the segment's own region geometry.
    const region = SEGMENT_REGIONS[SegmentIndex.First];
    for (const report of reports!) {
      expect(report.readUInt16LE(2)).toBe(region.x);
      expect(report.readUInt16LE(6)).toBe(region.width);
    }
  });

  it("does not repaint a segment when identical content is re-offered", () => {
    const cache = new SegmentCache();
    expect(cache.paint(SegmentIndex.Second, jpeg(9, 8, 7))).not.toBeNull();
    expect(cache.isDirty(SegmentIndex.Second, jpeg(9, 8, 7))).toBe(false);
    expect(cache.paint(SegmentIndex.Second, jpeg(9, 8, 7))).toBeNull();
  });

  it("repaints only when content changes", () => {
    const cache = new SegmentCache();
    cache.paint(SegmentIndex.Third, jpeg(1));
    expect(cache.paint(SegmentIndex.Third, jpeg(1, 2))).not.toBeNull();
    expect(cache.paint(SegmentIndex.Third, jpeg(1, 2))).toBeNull();
  });

  it("updating one segment never produces reports for the others", () => {
    const cache = new SegmentCache();
    // Prime all four segments.
    const initial = new Map<SegmentIndex, Uint8Array>([
      [SegmentIndex.First, jpeg(1)],
      [SegmentIndex.Second, jpeg(2)],
      [SegmentIndex.Third, jpeg(3)],
      [SegmentIndex.Fourth, jpeg(4)],
    ]);
    expect(cache.paintAll(initial)).toHaveLength(4);

    // Change only the Second segment; re-offer the rest unchanged.
    const next = new Map<SegmentIndex, Uint8Array>([
      [SegmentIndex.First, jpeg(1)],
      [SegmentIndex.Second, jpeg(2, 2)],
      [SegmentIndex.Third, jpeg(3)],
      [SegmentIndex.Fourth, jpeg(4)],
    ]);
    const paints = cache.paintAll(next);
    expect(paints.map((p) => p.index)).toEqual([SegmentIndex.Second]);
  });

  it("returns changed paints in ascending segment order", () => {
    const cache = new SegmentCache();
    const paints = cache.paintAll(
      new Map<SegmentIndex, Uint8Array>([
        [SegmentIndex.Fourth, jpeg(4)],
        [SegmentIndex.First, jpeg(1)],
        [SegmentIndex.Third, jpeg(3)],
      ]),
    );
    expect(paints.map((p) => p.index)).toEqual([
      SegmentIndex.First,
      SegmentIndex.Third,
      SegmentIndex.Fourth,
    ]);
  });

  it("invalidate forces the next paint to repaint", () => {
    const cache = new SegmentCache();
    cache.paint(SegmentIndex.First, jpeg(5, 5));
    expect(cache.paint(SegmentIndex.First, jpeg(5, 5))).toBeNull();
    cache.invalidate(SegmentIndex.First);
    expect(cache.paint(SegmentIndex.First, jpeg(5, 5))).not.toBeNull();
  });

  it("invalidate() with no index clears every segment", () => {
    const cache = new SegmentCache();
    cache.paintAll(
      new Map<SegmentIndex, Uint8Array>([
        [SegmentIndex.First, jpeg(1)],
        [SegmentIndex.Second, jpeg(2)],
      ]),
    );
    cache.invalidate();
    expect(cache.isDirty(SegmentIndex.First, jpeg(1))).toBe(true);
    expect(cache.isDirty(SegmentIndex.Second, jpeg(2))).toBe(true);
  });

  it("caches a defensive copy: mutating the caller's buffer does not desync", () => {
    const cache = new SegmentCache();
    const buf = jpeg(1, 2, 3);
    cache.paint(SegmentIndex.First, buf);
    buf[0] = 99; // mutate after caching
    // The cache still holds the original bytes, so the mutated buffer is dirty.
    expect(cache.isDirty(SegmentIndex.First, buf)).toBe(true);
    // And the original byte values are still recognised as clean.
    expect(cache.isDirty(SegmentIndex.First, jpeg(1, 2, 3))).toBe(false);
  });

  it("rejects out-of-range segment indices", () => {
    const cache = new SegmentCache();
    expect(() => cache.isDirty(-1 as SegmentIndex, jpeg(1))).toThrow(RangeError);
    expect(() => cache.paint(4 as SegmentIndex, jpeg(1))).toThrow(RangeError);
    expect(() => cache.invalidate(9 as SegmentIndex)).toThrow(RangeError);
  });
});

import { describe, expect, it } from "vitest";

import { SEGMENT_REGIONS, SegmentIndex, spanRegion, STRIP_REGION } from "../../src/touchStrip/geometry.js";
import { PanelCache, type EncodedPanel } from "../../src/touchStrip/panelCache.js";
import { HEADER_LENGTH, MAX_PAYLOAD } from "../../src/imageWriter/headerGenerator.js";

const first = SEGMENT_REGIONS[SegmentIndex.First];
const second = SEGMENT_REGIONS[SegmentIndex.Second];

const jpeg = (...bytes: number[]): Uint8Array => Uint8Array.from(bytes);

const panel = (region: EncodedPanel["region"], ...bytes: number[]): EncodedPanel => ({ region, jpeg: jpeg(...bytes) });

/** The four 200-wide segments, in strip order. */
const fourSegments = (seed: number): EncodedPanel[] =>
  SEGMENT_REGIONS.map((region, index) => panel(region, seed, index));

describe("PanelCache", () => {
  it("reports a never-painted panel as dirty and paints it", () => {
    const cache = new PanelCache();
    expect(cache.isDirty(panel(first, 1, 2))).toBe(true);
    expect(cache.paint(panel(first, 1, 2))).not.toBeNull();
  });

  it("treats identical bytes as clean and emits no writes", () => {
    const cache = new PanelCache();
    cache.paint(panel(first, 1, 2, 3));
    expect(cache.isDirty(panel(first, 1, 2, 3))).toBe(false);
    expect(cache.paint(panel(first, 1, 2, 3))).toBeNull();
  });

  it("treats a same-length but different payload as dirty", () => {
    const cache = new PanelCache();
    cache.paint(panel(first, 1, 2, 3));
    expect(cache.isDirty(panel(first, 1, 2, 4))).toBe(true);
  });

  it("caches a defensive copy so a later caller mutation cannot desync it", () => {
    const cache = new PanelCache();
    const bytes = jpeg(1, 2, 3);
    cache.paint({ region: first, jpeg: bytes });
    bytes[0] = 9;
    // The cached copy still holds the bytes that were actually written: the
    // mutated buffer reads as new content, and the original still reads clean.
    expect(cache.isDirty({ region: first, jpeg: bytes })).toBe(true);
    expect(cache.isDirty(panel(first, 1, 2, 3))).toBe(false);
  });

  it("keys panels by their rectangle, so two panels do not shadow each other", () => {
    const cache = new PanelCache();
    cache.paintAll([panel(first, 7), panel(second, 7)]);
    expect(cache.isDirty(panel(first, 7))).toBe(false);
    expect(cache.isDirty(panel(second, 7))).toBe(false);
    expect(cache.paintAll([panel(first, 7), panel(second, 8)]).map((paint) => paint.region)).toEqual([second]);
  });

  it("emits region writes carrying the panel's own geometry", () => {
    const cache = new PanelCache();
    const [paint] = cache.paintAll([panel(second, 1, 2, 3)]);
    for (const report of paint.reports) {
      expect(report.readUInt16LE(2)).toBe(second.x);
      expect(report.readUInt16LE(6)).toBe(second.width);
      expect(report.readUInt16LE(8)).toBe(second.height);
    }
  });

  it("chunks a wide panel's JPEG across as many reports as it needs", () => {
    const cache = new PanelCache();
    const big = { region: STRIP_REGION, jpeg: new Uint8Array(MAX_PAYLOAD + 10).fill(7) };
    const [paint] = cache.paintAll([big]);
    expect(paint.reports).toHaveLength(2);
    expect(paint.reports[0].readUInt16LE(6)).toBe(800);
    expect(paint.reports[1].readUInt8(10)).toBe(1);
    expect(paint.reports[1].readUInt16LE(13)).toBe(10);
    expect(paint.reports[1].readUInt8(HEADER_LENGTH)).toBe(7);
  });

  it("paints only the changed panels, in layout order", () => {
    const cache = new PanelCache();
    cache.paintAll(fourSegments(0));
    const next = fourSegments(0);
    next[1] = panel(second, 99);
    expect(cache.paintAll(next).map((paint) => paint.region.x)).toEqual([200]);
  });

  /**
   * A mode change re-tiles the strip. The old rectangles' cached bytes are no
   * longer what is on screen — the wide panel painted over them — so a return
   * to the old layout must repaint rather than match the stale cache.
   */
  it("repaints in full when the layout changes, and again when it changes back", () => {
    const cache = new PanelCache();
    cache.paintAll(fourSegments(0));
    expect(cache.paintAll([{ region: STRIP_REGION, jpeg: jpeg(5) }])).toHaveLength(1);
    expect(cache.paintAll(fourSegments(0))).toHaveLength(4);
  });

  it("treats a differently split centre as a different layout", () => {
    const cache = new PanelCache();
    const wide = spanRegion(SegmentIndex.Second, 2);
    cache.paintAll(fourSegments(0));
    const merged = [panel(first, 0, 0), panel(wide, 1), panel(SEGMENT_REGIONS[SegmentIndex.Fourth], 0, 3)];
    expect(cache.paintAll(merged)).toHaveLength(3);
  });

  it("invalidate forces the next paint of every panel", () => {
    const cache = new PanelCache();
    cache.paintAll(fourSegments(0));
    cache.invalidate();
    expect(cache.paintAll(fourSegments(0))).toHaveLength(4);
  });
});

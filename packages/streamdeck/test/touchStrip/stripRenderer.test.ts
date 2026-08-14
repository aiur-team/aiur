import { describe, expect, it } from "vitest";

import { SEGMENT_REGIONS, SegmentIndex } from "../../src/touchStrip/geometry.js";
import { pagerModel } from "../../src/touchStrip/pagerSegment.js";
import { providerSegmentModel } from "../../src/touchStrip/providerSegment.js";
import { summaryModel } from "../../src/touchStrip/summarySegment.js";
import { agentDetailModel } from "../../src/touchStrip/agentDetail.js";
import type { ProviderPanelRow } from "../../src/touchStrip/providerPanel.js";
import type { GridData, SegmentContent } from "../../src/touchStrip/stripLayout.js";
import { StripRenderer } from "../../src/touchStrip/stripRenderer.js";
import type { Region } from "../../src/imageWriter/headerGenerator.js";

/**
 * Deterministic stand-in encoder: identical content at the same width yields
 * identical bytes, which is the contract the cache's byte diff assumes.
 */
const jsonEncoder = (content: SegmentContent, region: Region): Uint8Array =>
  new TextEncoder().encode(JSON.stringify({ content, width: region.width }));

const provider = (label: string, usedPercent?: number): ProviderPanelRow => ({
  label,
  model:
    usedPercent === undefined
      ? providerSegmentModel(null)
      : providerSegmentModel({ provider: label, windows: { session: { used_percent: usedPercent, duration_minutes: 300 } } }),
});

const gridData = (overrides: Partial<GridData> = {}): { mode: "grid"; data: GridData } => ({
  mode: "grid",
  data: {
    summary: summaryModel(2, 3),
    providers: [provider("claude"), provider("codex")],
    providerOffset: 0,
    pager: pagerModel(9, 4, 1),
    pagerLabel: "5-8",
    ...overrides,
  },
});

const cmdData = (percent = 40) => ({
  mode: "cmd" as const,
  data: { detail: agentDetailModel({ identifier: "1356", bucket: "running", progress_percent: percent }) },
});

describe("StripRenderer", () => {
  it("paints every panel on the first render", () => {
    const paints = new StripRenderer(jsonEncoder).render(gridData());
    expect(paints.map((paint) => paint.region.x)).toEqual([0, 200, 400, 600]);
  });

  it("re-rendering identical data repaints nothing", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());
    expect(renderer.render(gridData())).toHaveLength(0);
  });

  it("updating one panel does NOT repaint the others", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());

    const paints = renderer.render(gridData({ providers: [provider("claude", 42), provider("codex")] }));

    expect(paints).toHaveLength(1);
    // And the write carries that panel's own region geometry.
    const region = SEGMENT_REGIONS[SegmentIndex.Second];
    expect(paints[0].region).toEqual(region);
    for (const report of paints[0].reports) {
      expect(report.readUInt16LE(2)).toBe(region.x);
      expect(report.readUInt16LE(6)).toBe(region.width);
    }
  });

  it("invalidate forces the next render to repaint everything", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());
    renderer.invalidate();
    expect(renderer.render(gridData())).toHaveLength(4);
  });

  it("switching to a mode that re-tiles the strip repaints the whole strip", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());
    const paints = renderer.render(cmdData());
    expect(paints).toHaveLength(1);
    expect(paints[0].region).toMatchObject({ x: 0, width: 800 });
  });

  it("growing the provider count re-tiles the centre and repaints the whole strip", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());
    const paints = renderer.render(gridData({ providers: [provider("claude"), provider("codex"), provider("kimi")] }));
    expect(paints.map((paint) => paint.region.width)).toEqual([200, 400, 200]);
  });

  /**
   * Returning to a layout the cache saw before must still repaint: the pixels
   * under those rectangles were overwritten by the wide panel in between, so a
   * cache hit on the old bytes would leave the previous mode on screen.
   */
  it("returning to an earlier layout repaints rather than trusting the stale cache", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());
    renderer.render(cmdData());
    expect(renderer.render(gridData())).toHaveLength(4);
  });

  it("keeps diffing within a mode after a re-tile", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(cmdData(10));
    expect(renderer.render(cmdData(10))).toHaveLength(0);
    expect(renderer.render(cmdData(11))).toHaveLength(1);
  });
});

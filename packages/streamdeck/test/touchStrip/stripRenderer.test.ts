import { describe, expect, it } from "vitest";

import { SEGMENT_REGIONS, SegmentIndex } from "../../src/touchStrip/geometry.js";
import { pagerModel } from "../../src/touchStrip/pagerSegment.js";
import { providerSegmentModel } from "../../src/touchStrip/providerSegment.js";
import { summaryModel } from "../../src/touchStrip/summarySegment.js";
import type { GridData, SegmentContent } from "../../src/touchStrip/stripLayout.js";
import { StripRenderer } from "../../src/touchStrip/stripRenderer.js";

/** Deterministic stand-in encoder: identical content yields identical bytes. */
const jsonEncoder = (content: SegmentContent): Uint8Array =>
  new TextEncoder().encode(JSON.stringify(content));

const gridData = (overrides: Partial<GridData> = {}): { mode: "grid"; data: GridData } => ({
  mode: "grid",
  data: {
    summary: summaryModel(2, 3),
    claude: providerSegmentModel(null),
    codex: providerSegmentModel(null),
    pager: pagerModel(9, 4, 1),
    pagerLabel: "5-8",
    ...overrides,
  },
});

describe("StripRenderer", () => {
  it("paints all four segments on the first render", () => {
    const renderer = new StripRenderer(jsonEncoder);
    const paints = renderer.render(gridData());
    expect(paints.map((p) => p.index)).toEqual([
      SegmentIndex.First,
      SegmentIndex.Second,
      SegmentIndex.Third,
      SegmentIndex.Fourth,
    ]);
  });

  it("re-rendering identical data repaints nothing", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());
    expect(renderer.render(gridData())).toHaveLength(0);
  });

  it("updating one segment does NOT repaint the others", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());

    // Change only the Claude (second) segment's usage.
    const claude = providerSegmentModel({
      provider: "claude",
      windows: { session: { used_percent: 42, duration_minutes: 300 } },
    });
    const paints = renderer.render(gridData({ claude }));

    expect(paints).toHaveLength(1);
    expect(paints[0].index).toBe(SegmentIndex.Second);
    // And the write carries the Claude segment's own region geometry.
    const region = SEGMENT_REGIONS[SegmentIndex.Second];
    for (const report of paints[0].reports) {
      expect(report.readUInt16LE(2)).toBe(region.x);
      expect(report.readUInt16LE(6)).toBe(region.width);
    }
  });

  it("invalidate forces the next render to repaint that segment", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());
    renderer.invalidate(SegmentIndex.First);
    const paints = renderer.render(gridData());
    expect(paints.map((p) => p.index)).toEqual([SegmentIndex.First]);
  });

  it("switching modes repaints the segments whose content changed", () => {
    const renderer = new StripRenderer(jsonEncoder);
    renderer.render(gridData());
    const paints = renderer.render({
      mode: "cmd",
      data: { identity: "agent-7", status: "working", percent: 40, ticketId: "1356" },
    });
    // All four segment kinds differ between grid and cmd, so all repaint.
    expect(paints).toHaveLength(4);
  });
});

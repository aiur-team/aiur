import { describe, expect, it, vi } from "vitest";
import { createPhysicalSurface, repaintGrid } from "../src/surface.js";

describe("physical surface composition", () => {
  it("repaints eight keys from the daemon grid and blacks out empty slots", async () => {
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    await repaintGrid({ sendFeatureReport }, {
      agents: [{ bucket: "running" }, { bucket: "paused" }],
      total: 2,
      windows: 1,
      max_column_offset: 0,
    });
    expect(sendFeatureReport).toHaveBeenCalledTimes(8);
    const reports = sendFeatureReport.mock.calls.map(([report]) => report as Uint8Array);
    expect(reports[0]?.[1]).toBe(0x06);
    expect(reports[0]?.[3]).toBeGreaterThan(0);
    expect(reports[7]?.slice(3, 6)).toEqual(Buffer.from([0, 0, 0]));
  });

  it("uses the production rasterizer and dirty cache for populated keys", async () => {
    const write = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const surface = createPhysicalSurface();
    const grid = { agents: [{ identifier: "1358", title: "Live proof", vendor: "codex", bucket: "running", progress_percent: 42, priority: false }], total: 1, windows: 1, max_column_offset: 0 };
    await surface.repaint({ write, sendFeatureReport } as never, grid);
    const firstWrites = write.mock.calls.length;
    expect(firstWrites).toBeGreaterThan(0);
    expect(write.mock.calls.some(([report]) => (report as Uint8Array)[1] === 0x07)).toBe(true);
    await surface.repaint({ write, sendFeatureReport } as never, grid);
    expect(write.mock.calls.length).toBeGreaterThanOrEqual(firstWrites);
  });
});

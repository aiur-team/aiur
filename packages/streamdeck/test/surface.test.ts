import { describe, expect, it, vi } from "vitest";
import { createPhysicalSurface, repaintGrid } from "../src/surface.js";
import { layoutPhysicalKeys } from "../src/keys.js";

describe("physical surface composition", () => {
  it("places command faces on the exact keys their controller handles", () => {
    const descriptors = layoutPhysicalKeys([
      { identifier: "pause", title: "Pause", vendor: "command", bucket: "queued", progress_percent: 0, priority: false },
      { identifier: "priority", title: "Prioritize", vendor: "command", bucket: "queued", progress_percent: 0, priority: false },
      { identifier: "logs", title: "Logs", vendor: "command", bucket: "queued", progress_percent: 0, priority: false },
      { identifier: "mic", title: "Mic", vendor: "command", bucket: "queued", progress_percent: 0, priority: false },
    ]);
    expect(descriptors.slice(0, 4).map((descriptor) => descriptor.kind === "agent" ? descriptor.title : "empty")).toEqual(["Pause", "Prioritize", "Logs", "Mic"]);
    expect(descriptors.slice(4).every((descriptor) => descriptor.kind === "empty")).toBe(true);
  });
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

  it("renders event-window changes separately from transcript changes", async () => {
    const write = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const surface = createPhysicalSurface();
    const backend = { write, sendFeatureReport } as never;
    const grid = { agents: [], total: 0, windows: 1, max_column_offset: 0 };
    const base = { mode: "logs" as const, focusedIdentifier: null, columnOffset: 0, eventLines: [
      { kind: "event" as const, badge: "EMIT", text: "event-a", time: "1m" },
      { kind: "event" as const, badge: "CONSUME", text: "event-b", time: "2m" },
      { kind: "event" as const, badge: "INFO", text: "event-c", time: "3m" },
    ], eventOffset: 0, transcriptLines: ["chat-a", "chat-b"], eventHasNext: true, chatHasNext: true };
    await surface.repaint(backend, grid, {}, undefined, base);
    const first = write.mock.calls.length;
    await surface.repaint(backend, grid, {}, undefined, { ...base, eventOffset: 1 });
    const afterEvent = write.mock.calls.length;
    await surface.repaint(backend, grid, {}, undefined, { ...base, eventOffset: 1, transcriptLines: ["chat-b", "chat-c"] });
    expect(afterEvent).toBeGreaterThan(first);
    expect(write.mock.calls.length).toBeGreaterThan(afterEvent);
  });
});

import { afterEach, expect, it, vi } from "vitest";
import { createCanvas } from "@napi-rs/canvas";
import { createPhysicalSurface } from "../src/surface.js";
import { KeyRenderer } from "../src/keys/keyRenderer.js";
import { composeKeyFace } from "../src/keys/keyFace.js";
import { createPhysicalController } from "../src/controller.js";
import { descriptorCommands } from "../src/surface.js";
import { keyReport } from "./support/deckReports.js";
import { drawKey } from "../src/key-face.js";

afterEach(() => vi.restoreAllMocks());

it("carries Build labels from the wire grid through physical descriptors and paints unknown progress without a bar", async () => {
  const render = vi.spyOn(KeyRenderer.prototype, "render").mockReturnValue([]);
  const backend = { write: vi.fn(), sendFeatureReport: vi.fn() } as never;
  const grid = { agents: [
    { identifier: "1", title: "CI ticket", bucket: "paused", face: "idle", label: "Waiting for CI", progress_percent: null },
    { identifier: "2", title: "Unknown ticket", bucket: "paused", face: "unknown", label: "State unknown", progress_percent: null },
    { identifier: "3", title: "Retry ticket", bucket: "paused", face: "queued", label: "Retrying", progress_percent: 40 },
  ], total: 3, windows: 1, max_column_offset: 0 };
  await createPhysicalSurface().repaint(backend, grid);
  const descriptors = render.mock.lastCall![0];
  for (const [slot, label] of [[0, "Waiting for CI"], [4, "State unknown"], [1, "Retrying"]] as const) {
    const descriptor = descriptors[slot]!;
    const accent = label === "Retrying" ? "#9096a4" : "#c2c6cf";
    expect(descriptor).toMatchObject({ style: { accent } });
    expect(descriptor).toMatchObject({ kind: "agent", stateLabel: label, style: { label } });
    const canvas = createCanvas(120, 120);
    const context = canvas.getContext("2d");
    const text = vi.spyOn(context, "fillText");
    const rect = vi.spyOn(context, "roundRect");
    drawKey(canvas, composeKeyFace(descriptor));
    expect(text.mock.calls.some(([value]) => value === label)).toBe(true);
    const bars = rect.mock.calls.filter(([, , , height]) => height === 6);
    expect(bars.length).toBe(label === "Retrying" ? 2 : 0);
  }
});

// Future guard: palette metadata must never select a control action.
it("keeps retrying and unknown faces on Pause unless control metadata says paused", () => {
  for (const face of ["queued", "unknown"]) {
    const agent = { identifier: "77", title: "Ticket", bucket: "stuck", face };
    expect(descriptorCommands(agent, false, false)[0]?.title).toBe("Pause");
    const control = vi.fn();
    const grid = { agents: [agent], total: 1, windows: 1, max_column_offset: 0 };
    const controller = createPhysicalController({ grid: () => grid, channel: () => ({ focus: vi.fn(), control, say: vi.fn(), commandsPage: vi.fn(), answerCommand: vi.fn() }), stateChanged: vi.fn() });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(0, true));
    expect(control).toHaveBeenCalledWith("77", "pause");
  }
});

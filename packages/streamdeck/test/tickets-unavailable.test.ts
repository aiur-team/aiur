import { afterEach, expect, it, vi } from "vitest";
import { createCanvas } from "@napi-rs/canvas";
import { createPhysicalSurface } from "../src/surface.js";
import { createPhysicalController } from "../src/controller.js";
import { KeyRenderer } from "../src/keys/keyRenderer.js";
import { composeKeyFace } from "../src/keys/keyFace.js";
import { drawKey } from "../src/key-face.js";
import { keyReport } from "./support/deckReports.js";

afterEach(() => vi.restoreAllMocks());

it("paints unavailable ticket evidence on a non-actionable key even after paging", async () => {
  const render = vi.spyOn(KeyRenderer.prototype, "render").mockReturnValue([]);
  const grid = { tickets_status: "unavailable", agents: [], total: 0, windows: 0, max_column_offset: 0 };
  const backend = { write: vi.fn(), sendFeatureReport: vi.fn() } as never;
  await createPhysicalSurface().repaint(backend, grid, {}, undefined, { mode: "grid", focusedIdentifier: null, columnOffset: 4 });
  const descriptors = render.mock.lastCall![0];
  expect(descriptors[0]).toMatchObject({ kind: "agent", role: "command", title: "Tickets unavailable", subLabel: "UNAVAILABLE", progressPercent: null });
  expect(descriptors.slice(1)).toEqual(Array.from({ length: 7 }, () => ({ kind: "empty" })));

  const canvas = createCanvas(120, 120);
  const context = canvas.getContext("2d");
  const text = vi.spyOn(context, "fillText");
  drawKey(canvas, composeKeyFace(descriptors[0]));
  const words = text.mock.calls.map(([value]) => value).join(" ");
  expect(words).toContain("Tickets");
  expect(words).toContain("unavailable");
  expect(words).not.toContain("0%");

  const focus = vi.fn();
  const control = vi.fn();
  const controller = createPhysicalController({ grid: () => grid, channel: () => ({ focus, control, say: vi.fn(), commandsPage: vi.fn(), answerCommand: vi.fn() }), stateChanged: vi.fn() });
  controller.handleReport(keyReport(0, true));
  controller.handleReport(keyReport(0, false));
  expect(focus).not.toHaveBeenCalled();
  expect(control).not.toHaveBeenCalled();
  expect(grid.agents).toEqual([]);
});

import { createCanvas } from "@napi-rs/canvas";
import { describe, expect, it, vi } from "vitest";
import { demoGrid, demoTicket } from "../src/demo.js";
import { createPhysicalController } from "../src/controller.js";
import { createPhysicalSurface } from "../src/surface.js";
import { surfaceState } from "../src/sidecar-wiring.js";
import { keyReport } from "./support/deckReports.js";

const now = Date.now();

describe("demo ticket page", () => {
  it("paints synthetic ticket evidence after selecting a demo key, overriding colliding live data", async () => {
    const grid = demoGrid();
    const controller = createPhysicalController({ grid: () => grid, channel: () => null, stateChanged: () => undefined });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    const id = controller.state().focusedIdentifier;
    expect(id).toBe("401");
    const dto = demoTicket(grid, id, now)!;
    controller.setTicket({ ...dto, title: "Colliding live ticket", status: { label: "Live status", tone: "idle", agent_state: null } });
    const context = createCanvas(800, 100).getContext("2d");
    const fillText = vi.spyOn(Object.getPrototypeOf(context), "fillText");
    try {
      const surface = createPhysicalSurface();
      const backend = { write: vi.fn(async () => undefined), sendFeatureReport: vi.fn(async () => undefined) } as never;
      const state = surfaceState(controller.state(), [], undefined, grid);
      await surface.repaint(backend, grid, {}, undefined, state);
      const painted = fillText.mock.calls.map(([text]) => text);
      expect(painted).toContain("Auth refactor and session rotation");
      expect(painted).toContain("RUNNING");
      expect(painted).toContain("72%");
      expect(painted).not.toContain("Colliding live ticket");
      expect(painted).not.toContain("LIVE STATUS");
    } finally {
      fillText.mockRestore();
    }
  });

  it("preserves absent readings and uses Build status fixtures for each demo bucket", () => {
    const grid = demoGrid();
    const current = demoTicket(grid, "401")!;
    expect(current.agent?.start).toBe(current.observed_at! - 11_240_000);
    expect(demoTicket(grid, null, now)).toBeNull();
    expect(demoTicket(grid, "missing", now)).toBeNull();
    expect(demoTicket(grid, "640", now)?.agent?.pct).toBeNull();
    expect(demoTicket(grid, "620", now)?.agent?.start).toBeNull();
    for (const [id, label] of [["333", "Error"], ["540", "Awaiting command"], ["620", "Paused"], ["881", "Queued · Q?"]]) {
      expect(demoTicket(grid, id, now)?.status.label).toBe(label);
    }
    const future = { ...grid, agents: [{ identifier: "future", title: "New bucket", vendor: "codex", bucket: "future" }] };
    expect(demoTicket(future, "future", now)?.status.label).toBe("State unknown");
  });
});

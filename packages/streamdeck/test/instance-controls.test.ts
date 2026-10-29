import { expect, it, vi } from "vitest";
import { createPhysicalController } from "../src/controller.js";
import { dialButton, dialButtons, dialTurn, keyReport } from "./support/deckReports.js";
import { render } from "./art/renderSegment.js";
import { StripRenderer } from "../src/touchStrip/stripRenderer.js";
import type { SegmentContent } from "../src/touchStrip/stripLayout.js";

const grid = () => ({ agents: [{ identifier: "LOCAL-1", bucket: "running" }], total: 1, windows: 1, max_column_offset: 0 });
it("routes dial 3 turns and releases, but suppresses both chord press orders", () => {
  const turnInstance = vi.fn(); const switchInstance = vi.fn(); const toggleDemo = vi.fn();
  const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn(), turnInstance, switchInstance, toggleDemo });
  controller.handleReport(dialTurn(2, 1)); expect(turnInstance).toHaveBeenCalledWith(1); expect(switchInstance).not.toHaveBeenCalled();
  controller.handleReport(dialButton(2)); expect(switchInstance).not.toHaveBeenCalled();
  controller.handleReport(dialButton(2, false)); expect(switchInstance).toHaveBeenCalledOnce();
  for (const first of [1, 2]) {
    controller.handleReport(dialButton(first)); controller.handleReport(dialButtons([1, 2]));
    controller.handleReport(dialButtons([1, 2])); controller.handleReport(dialButton(first));
    controller.handleReport(dialButtons([], false));
  }
  expect(switchInstance).toHaveBeenCalledOnce(); expect(toggleDemo).toHaveBeenCalledTimes(2);
  controller.handleReport(dialButton(2)); controller.cancel(); controller.handleReport(dialButton(2, false));
  expect(switchInstance).toHaveBeenCalledOnce();
});

it("clears old instance focus, logs, commands and held voice on reset", () => {
  const dispose = vi.fn();
  const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn(), voice: () => ({ hold: vi.fn(), release: vi.fn(), message: () => "", hasMessage: () => false, clear: vi.fn(), dispose, microphones: () => [], refresh: vi.fn(), selectedDeviceId: () => null, select: vi.fn() }) });
  controller.handleReport(keyReport(0, true)); controller.handleReport(keyReport(0, false));
  controller.handleReport(keyReport(2, true)); expect(controller.state().micHeld).toBe(true);
  controller.setLogs({ transcript: [{ kind: "message", body: "local transcript" }] }); controller.resetInstance();
  expect(controller.state()).toMatchObject({ mode: "grid", focusedIdentifier: null, micHeld: false, transcriptRows: [], commandsPage: { items: [] } });
  expect(dispose).toHaveBeenCalled();
});

it("carries instance status through renderer into actual painted text in any mode", () => {
  const painted: SegmentContent[] = [];
  const renderer = new StripRenderer((content) => { painted.push(content); return new TextEncoder().encode(JSON.stringify(content)); });
  const data = { mode: "cmd" as const, data: {  } };
  renderer.render(data, "local · connected | ◀ remote ▶ · press to connect");
  expect(painted[0]).toMatchObject({ kind: "instance", label: "local · connected | ◀ remote ▶ · press to connect" });
  const { ink } = render(painted[0]!, 800);
  expect(ink.map((entry) => entry.text)).toContain("local · connected");
  expect(ink.map((entry) => entry.text)).toContain("◀ remote ▶ · press to connect");
  expect(ink.map((entry) => entry.text)).toContain("Conversation unavailable");
  const failure = render({ kind: "instance", label: "remote · auth failed", content: { kind: "blank" } }, 800);
  expect(failure.ink.map((entry) => entry.text)).toContain("remote · auth failed");
  expect(renderer.render(data, "remote · auth failed")).toHaveLength(1);
});

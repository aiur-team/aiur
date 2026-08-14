import { describe, expect, it, vi } from "vitest";
import { createPhysicalController } from "../src/controller.js";
import type { StreamDeckGrid } from "../src/channel.js";

const grid = (count = 10): StreamDeckGrid => ({
  agents: Array.from({ length: count }, (_, index) => ({
    identifier: `agent-${index}`,
    bucket: index === 6 ? "running" : "queued",
    title: `Agent ${index}`,
    vendor: "codex",
    progress_percent: 20,
  })),
  total: count,
  windows: Math.ceil(count / 8),
  max_column_offset: Math.max(0, Math.ceil(count / 2) - 4),
});

const keyReport = (index: number, pressed: boolean): Uint8Array => {
  const report = new Uint8Array(12);
  report[0] = 1;
  report[4 + index] = pressed ? 1 : 0;
  return report;
};

const keysReport = (indices: number[], pressed: boolean): Uint8Array => {
  const report = new Uint8Array(12);
  report[0] = 1;
  for (const index of indices) report[4 + index] = pressed ? 1 : 0;
  return report;
};

const dialButton = (index: number, pressed = true): Uint8Array => {
  const report = new Uint8Array(10);
  report[0] = 1;
  report[1] = 3;
  report[4] = 0;
  report[5 + index] = pressed ? 1 : 0;
  return report;
};

const dialTurn = (index: number, ticks: number): Uint8Array => {
  const report = new Uint8Array(10);
  report[0] = 1;
  report[1] = 3;
  report[4] = 1;
  report[5 + index] = ticks;
  return report;
};

describe("physical controller composition", () => {
  it("focuses the pressed grid agent and controls that same agent in cmd mode", () => {
    const focus = vi.fn();
    const control = vi.fn();
    const changed = vi.fn();
    const controller = createPhysicalController({ grid, channel: () => ({ focus, control }), stateChanged: changed });

    controller.handleReport(keyReport(3, true));
    controller.handleReport(keyReport(3, false));
    expect(controller.state()).toMatchObject({ mode: "cmd", focusedIdentifier: "agent-6" });
    expect(focus).toHaveBeenCalledWith("agent-6");

    controller.handleReport(keyReport(0, true));
    expect(control).toHaveBeenCalledWith("agent-6", "pause");
    expect(changed).toHaveBeenCalled();

    const resume = vi.fn();
    const pausedGrid = (): StreamDeckGrid => ({ ...grid(), agents: grid().agents.map((agent, index) => index === 6 ? { ...agent, bucket: "paused" } : agent) });
    const pausedController = createPhysicalController({ grid: pausedGrid, channel: () => ({ focus: vi.fn(), control: resume }), stateChanged: vi.fn() });
    pausedController.handleReport(keyReport(3, true));
    pausedController.handleReport(keyReport(3, false));
    pausedController.handleReport(keyReport(0, true));
    expect(resume).toHaveBeenCalledWith("agent-6", "resume");
  });

  it("uses the same column-major mapping as the rendered grid at every key and offset", () => {
    for (const offset of [0, 4]) {
      for (const key of Array.from({ length: 8 }, (_, index) => index)) {
        const focus = vi.fn();
        const controller = createPhysicalController({ grid: () => grid(20), channel: () => ({ focus, control: vi.fn() }), stateChanged: vi.fn() });
        if (offset !== 0) {
          controller.handleReport(dialButton(3));
          controller.handleReport(dialButton(3, false));
        }
        controller.handleReport(keyReport(key, true));
        controller.handleReport(keyReport(key, false));
        const column = key % 4;
        const row = key < 4 ? 0 : 1;
        const expected = `agent-${(offset + column) * 2 + row}`;
        expect(controller.state().focusedIdentifier).toBe(expected);
        expect(focus).toHaveBeenCalledWith(expected);
      }
    }
  });

  it("keeps the physical mic hold local and clears it on release", () => {
    const controller = createPhysicalController({ grid, channel: () => ({ focus: vi.fn(), control: vi.fn() }), stateChanged: vi.fn() });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(3, true));
    expect(controller.state().micHeld).toBe(true);
    controller.handleReport(keyReport(3, false));
    expect(controller.state().micHeld).toBe(false);
  });

  it("pages, enters logs, scrolls chat, and backs out through the physical controls", () => {
    const changed = vi.fn();
    const controller = createPhysicalController({ grid: () => grid(20), channel: () => null, stateChanged: changed });
    controller.setTranscript(["one", "two", "three", "four"]);
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    expect(controller.state().mode).toBe("logs");
    controller.handleReport(dialTurn(0, -1));
    expect(controller.state().chatOffset).toBe(0);
    controller.handleReport(dialTurn(0, 1));
    controller.handleReport(dialTurn(1, 1));
    controller.handleReport(dialTurn(3, 1));
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    controller.handleReport(dialButton(1));
    controller.handleReport(dialButton(1, false));
    controller.handleReport(dialButton(0));
    expect(controller.state().mode).toBe("cmd");
    controller.handleReport(dialButton(0, false));
    controller.handleReport(dialButton(0));
    expect(controller.state().mode).toBe("grid");
    expect(changed.mock.calls.length).toBeGreaterThan(2);
  });

  it("keeps event paging visible and transcript scrolling independent", () => {
    const changed = vi.fn();
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: changed });
    controller.setLogs({
      event_keys: Array.from({ length: 12 }, (_, index) => ({ label: `event-${index}` })),
      events_max_offset: 4,
      transcript: [{ body: "chat-a" }, { body: "chat-b" }, { body: "chat-c" }, { body: "chat-d" }],
      transcript_max_offset: 2,
    });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(2, true));
    controller.handleReport(keyReport(2, false));
    expect(controller.state().mode).toBe("logs");
    const before = controller.state();
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    expect(controller.state().eventOffset).toBeGreaterThan(before.eventOffset);
    expect(controller.state().eventLines.map((event) => event.text)).toContain("event-0");
    const eventOffset = controller.state().eventOffset;
    controller.handleReport(dialTurn(0, 1));
    expect(controller.state().chatOffset).toBeGreaterThan(0);
    expect(controller.state().eventOffset).toBe(eventOffset);
    expect(controller.state().chatHasPrevious).toBe(true);
    expect(changed).toHaveBeenCalled();
  });

  it("preserves both log offsets across live refreshes and clears mic on cancellation", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.setLogs({
      event_keys: Array.from({ length: 12 }, (_, index) => ({ label: `event-${index}` })),
      transcript: Array.from({ length: 6 }, (_, index) => ({ body: `line-${index}` })),
      events_max_offset: 4,
      transcript_max_offset: 4,
      events_offset: 2,
      transcript_offset: 2,
    });
    // Enter command mode and then Logs through the production input path.
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    expect(controller.state().mode).toBe("logs");
    controller.handleReport(dialTurn(3, 1));
    controller.handleReport(dialTurn(0, 1));
    const { eventOffset, chatOffset } = controller.state();
    controller.handleReport(dialButton(0));
    controller.handleReport(dialButton(0, false));
    controller.handleReport(keyReport(3, true));
    expect(controller.state().micHeld).toBe(true);
    controller.cancel();
    expect(controller.state().micHeld).toBe(false);
    controller.handleReport(keyReport(3, false));
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    expect(controller.state().mode).toBe("logs");
    controller.setLogs({ event_keys: Array.from({ length: 12 }, (_, index) => ({ label: `refresh-${index}` })), transcript: Array.from({ length: 6 }, (_, index) => ({ body: `refresh-${index}` })), events_max_offset: 4, transcript_max_offset: 4 });
    expect(controller.state().eventOffset).toBe(eventOffset);
    expect(controller.state().chatOffset).toBe(chatOffset);
  });

  // Flattening each event key to one display string discarded the direction
  // badge and the relative timestamp, so every log key painted an identical
  // grey INFO badge with no time.
  it("keeps each event key's direction badge and timestamp", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.setLogs({
      event_keys: [
        { kind: "live", label: "LIVE" },
        { kind: "event", badge: "EMIT", text: "Dependency cleared", time: "3m" },
        { kind: "event", badge: "SYSTEM", text: "Daemon reloaded", time: "12m" },
      ],
    });
    expect(controller.state().eventLines).toEqual([
      { kind: "live", badge: "LIVE", text: "LIVE", time: "" },
      { kind: "event", badge: "EMIT", text: "Dependency cleared", time: "3m" },
      { kind: "event", badge: "SYSTEM", text: "Daemon reloaded", time: "12m" },
    ]);
  });

  it("falls back to INFO for an event with no badge", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.setLogs({ event_keys: [{ kind: "event", text: "no badge here" }] });
    expect(controller.state().eventLines[0]).toEqual({ kind: "event", badge: "INFO", text: "no badge here", time: "" });
  });

  it("clears a held mic when Logs rises in the same report", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(3, true));
    expect(controller.state().micHeld).toBe(true);
    controller.handleReport(keysReport([2, 3], true));
    expect(controller.state()).toMatchObject({ mode: "logs", micHeld: false });
  });

  it("accumulates dial detents before converting short ranges to offsets", () => {
    const controller = createPhysicalController({ grid: () => grid(20), channel: () => null, stateChanged: vi.fn() });
    controller.handleReport(dialTurn(3, 1));
    expect(controller.state().columnOffset).toBe(0);
    controller.handleReport(dialTurn(3, 1));
    expect(controller.state().columnOffset).toBe(0);
    controller.handleReport(dialTurn(3, 1));
    expect(controller.state().columnOffset).toBe(1);
  });

  it("synchronizes dial D with the server-selected event offset when logs arrive", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.setLogs({
      event_keys: Array.from({ length: 20 }, (_, index) => ({ label: `event-${index}` })),
      events_offset: 8,
      events_max_offset: 12,
      transcript: [{ body: "chat" }],
      transcript_offset: 0,
    });
    expect(controller.state().eventOffset).toBe(8);
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    controller.handleReport(dialTurn(3, 1));
    expect(controller.state().eventOffset).toBe(9);
  });
});

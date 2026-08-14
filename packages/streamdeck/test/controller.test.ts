import { describe, expect, it, vi } from "vitest";
import { createPhysicalController } from "../src/controller.js";
import type { StreamDeckGrid } from "../src/channel.js";
import { dialButton, dialButtons, dialTurn, keyReport, keysReport } from "./support/deckReports.js";

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
    controller.setLogs({
      transcript: ["one", "two", "three", "four"].map((body) => ({ kind: "message", role: "assistant", body })),
      transcript_max_offset: 2,
    });
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

  describe("jump to the transcript position an event was published at", () => {
    // Three events, flattened the way the daemon flattens them: newest event
    // first, each header immediately followed by that event's own entries.
    const transcript = [
      { kind: "event_header", badge: "EMIT", body: "Dependency cleared", timestamp: "2026-08-13T03:00:00Z" },
      { kind: "message", role: "assistant", body: "unblocking" },
      { kind: "diff", path: "lib/a.ex", additions: 3, deletions: 1, line: "+  ok" },
      { kind: "event_header", badge: "AGENT", body: "Rebased", timestamp: "2026-08-13T02:57:00Z" },
      { kind: "message", role: "assistant", body: "rebasing" },
      { kind: "event_header", badge: "SYSTEM", body: "Fixtures reloaded", timestamp: "2026-08-13T02:51:00Z" },
      { kind: "message", role: "system", body: "reloaded" },
      { kind: "message", role: "system", body: "done" },
    ];
    const eventKeys = [
      { kind: "live", label: "LIVE" },
      { kind: "event", badge: "EMIT", text: "Dependency cleared", time: "now" },
      { kind: "event", badge: "AGENT", text: "Rebased", time: "3m" },
      { kind: "event", badge: "SYSTEM", text: "Fixtures reloaded", time: "9m" },
    ];

    /** A controller sitting on the logs surface with the fixture feed loaded. */
    const inLogs = (logs: Parameters<ReturnType<typeof createPhysicalController>["setLogs"]>[0] = { event_keys: eventKeys, transcript }) => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs(logs);
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      controller.handleReport(keyReport(2, true));
      controller.handleReport(keyReport(2, false));
      expect(controller.state().mode).toBe("logs");
      return controller;
    };

    it("scrolls the transcript to each event's header", () => {
      const controller = inLogs();
      for (const [key, start] of [[1, 0], [2, 3], [3, 5]] as const) {
        controller.handleReport(keyReport(key, true));
        controller.handleReport(keyReport(key, false));
        expect(controller.state().chatOffset).toBe(start);
        expect(controller.state().transcriptRows[0]).toMatchObject({ kind: "event_header" });
      }
    });

    // LIVE is the feed's sentinel row rather than an event, and the daemon
    // flattens newest-first, so it lands on the head of the transcript.
    it("jumps to the newest entry from the LIVE key", () => {
      const controller = inLogs();
      controller.handleReport(keyReport(3, true));
      controller.handleReport(keyReport(3, false));
      expect(controller.state().chatOffset).toBe(5);
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      expect(controller.state().chatOffset).toBe(0);
      expect(controller.state().transcriptRows[0]).toMatchObject({ kind: "event_header", badge: "EMIT" });
    });

    // The key window and the event list are different index spaces; reading the
    // press as a bare key index jumps to the wrong event after a page.
    it("jumps to the event under the key after the window is paged", () => {
      const controller = inLogs({ event_keys: eventKeys, transcript, events_max_offset: 2 });
      controller.handleReport(dialTurn(3, 1));
      expect(controller.state().eventOffset).toBe(1);
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
      expect(controller.state().chatOffset).toBe(3);
    });

    it("keeps dial A scrolling from wherever the jump landed", () => {
      const controller = inLogs();
      controller.handleReport(keyReport(2, true));
      controller.handleReport(keyReport(2, false));
      controller.handleReport(dialTurn(0, 1));
      expect(controller.state().chatOffset).toBe(4);
      controller.handleReport(dialTurn(0, -1));
      expect(controller.state().chatOffset).toBe(3);
    });

    it("ignores a press on a slot with no event", () => {
      const controller = inLogs();
      controller.handleReport(keyReport(2, true));
      controller.handleReport(keyReport(2, false));
      const before = controller.state().chatOffset;
      controller.handleReport(keyReport(7, true));
      controller.handleReport(keyReport(7, false));
      expect(controller.state().chatOffset).toBe(before);
    });

    // A diff carries no `line` and no `body`; collapsing rows to one display
    // string printed the literal "[INFO]" for every one of them.
    it("keeps each transcript row's shape", () => {
      const controller = inLogs();
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
      controller.handleReport(dialTurn(0, 2));
      expect(controller.state().transcriptRows[0]).toEqual({ kind: "diff", path: "lib/a.ex", additions: 3, deletions: 1, line: "+  ok" });
    });

    // The LIVE key and a header-less event key must not share a fallback, or
    // the LIVE branch could be deleted without a single test noticing.
    it("ignores an event key whose event has no header in the transcript", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs({ event_keys: eventKeys, transcript: transcript.slice(3), transcript_offset: 2 });
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      controller.handleReport(keyReport(2, true));
      controller.handleReport(keyReport(2, false));
      // Two headers under three event keys: key 2 lands on the second header,
      // key 3 addresses nothing and must leave the position alone.
      controller.handleReport(keyReport(2, true));
      controller.handleReport(keyReport(2, false));
      const before = controller.state().chatOffset;
      expect(before).toBe(2);
      controller.handleReport(keyReport(3, true));
      controller.handleReport(keyReport(3, false));
      expect(controller.state().chatOffset).toBe(before);
    });

    it("opens the surface on the newest entry when the server sends no offset", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs({ event_keys: eventKeys, transcript });
      expect(controller.state().chatOffset).toBe(0);
    });

    it("repaints the transcript window when logs is re-entered", () => {
      const controller = inLogs();
      controller.handleReport(dialButton(0));
      controller.handleReport(dialButton(0, false));
      expect(controller.state()).toMatchObject({ mode: "cmd", transcriptRows: [] });
      controller.handleReport(dialButton(3));
      controller.handleReport(dialButton(3, false));
      expect(controller.state().mode).toBe("logs");
      expect(controller.state().transcriptRows).toHaveLength(2);
    });

    it("keeps an event header's badge, body and timestamp", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs({ transcript: [transcript[0], { kind: "event_header", timestamp: "" }] });
      expect(controller.state().transcriptRows).toEqual([
        { kind: "event_header", badge: "EMIT", body: "Dependency cleared", timestamp: "2026-08-13T03:00:00Z" },
        { kind: "event_header", badge: "INFO", body: "", timestamp: null },
      ]);
    });

    it("normalises a diff with no line and an unknown row shape", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs({
        transcript: [{ kind: "diff", path: "lib/b.ex" }, { kind: "mystery", body: "hello" }, { body: "no kind" }],
        transcript_offset: 0,
      });
      expect(controller.state().transcriptRows).toEqual([
        { kind: "diff", path: "lib/b.ex", additions: 0, deletions: 0, line: null },
        { kind: "message", role: "system", body: "hello" },
      ]);
    });
  });

  it("falls back to INFO for an event with no badge", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.setLogs({ event_keys: [{ kind: "event", text: "no badge here" }] });
    expect(controller.state().eventLines[0]).toEqual({ kind: "event", badge: "INFO", text: "no badge here", time: "" });
  });

  describe("demo chord", () => {
    it("toggles when the two chord keys are held together", () => {
      const toggleDemo = vi.fn();
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn(), toggleDemo });
      controller.handleReport(dialButtons([1, 2]));
      expect(toggleDemo).toHaveBeenCalledOnce();
    });

    // Holding the pair must not retrigger on every poll.
    it("fires once while the chord stays held", () => {
      const toggleDemo = vi.fn();
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn(), toggleDemo });
      controller.handleReport(dialButtons([1, 2]));
      controller.handleReport(dialButtons([1, 2]));
      controller.handleReport(dialButtons([1, 2]));
      expect(toggleDemo).toHaveBeenCalledOnce();
    });

    it("fires again after the chord is released and re-held", () => {
      const toggleDemo = vi.fn();
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn(), toggleDemo });
      controller.handleReport(dialButtons([1, 2]));
      controller.handleReport(dialButtons([], false));
      controller.handleReport(dialButtons([1, 2]));
      expect(toggleDemo).toHaveBeenCalledTimes(2);
    });

    it("does not disturb the surface when fired from the grid", () => {
      const toggleDemo = vi.fn();
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn(), toggleDemo });
      controller.handleReport(dialButtons([1, 2]));
      expect(controller.state().mode).toBe("grid");
      expect(controller.state().focusedIdentifier).toBeNull();
    });

    it("returns to the grid when the chord is hit from the command surface", () => {
      const toggleDemo = vi.fn();
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn(), toggleDemo });
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      expect(controller.state().mode).toBe("cmd");
      controller.handleReport(dialButtons([1, 2]));
      expect(controller.state().mode).toBe("grid");
      expect(toggleDemo).toHaveBeenCalledOnce();
    });

    // The middle two knob presses carry no action of their own, so with no demo
    // host wired the chord is simply inert — it cannot shadow anything.
    it("is inert when no demo host is wired", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.handleReport(dialButtons([1, 2]));
      expect(controller.state().mode).toBe("grid");
    });

    it("leaves the back and window-cycle knobs working", () => {
      const toggleDemo = vi.fn();
      const controller = createPhysicalController({ grid: () => grid(20), channel: () => null, stateChanged: vi.fn(), toggleDemo });
      controller.handleReport(dialButton(3));
      controller.handleReport(dialButton(3, false));
      expect(toggleDemo).not.toHaveBeenCalled();
      expect(controller.state().columnOffset).toBeGreaterThan(0);
    });
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

  // Routing a detent through the mock's 0-100 knob value made one click worth a
  // fraction of a column, so the operator had to click two or three times for
  // every step. A detent is one position.
  it("moves the grid exactly one column per dial detent", () => {
    const controller = createPhysicalController({ grid: () => grid(20), channel: () => null, stateChanged: vi.fn() });
    controller.handleReport(dialTurn(3, 1));
    expect(controller.state().columnOffset).toBe(1);
    controller.handleReport(dialTurn(3, 1));
    expect(controller.state().columnOffset).toBe(2);
    controller.handleReport(dialTurn(3, -1));
    expect(controller.state().columnOffset).toBe(1);
  });

  it("applies a multi-detent report in one step", () => {
    const controller = createPhysicalController({ grid: () => grid(20), channel: () => null, stateChanged: vi.fn() });
    controller.handleReport(dialTurn(3, 3));
    expect(controller.state().columnOffset).toBe(3);
  });

  it("clamps at both ends of the column range", () => {
    // 20 agents -> ceil(20/2) - 4 = 6 columns of travel.
    const controller = createPhysicalController({ grid: () => grid(20), channel: () => null, stateChanged: vi.fn() });
    controller.handleReport(dialTurn(3, 99));
    expect(controller.state().columnOffset).toBe(6);
    controller.handleReport(dialTurn(3, -99));
    expect(controller.state().columnOffset).toBe(0);
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

import { describe, expect, it, vi } from "vitest";
import { createPhysicalController } from "../src/controller.js";
import type { StreamDeckGrid } from "../src/channel.js";
import { dialButton, dialButtons, dialTurn, keyReport, keysReport } from "./support/deckReports.js";
import { PROVIDER_SCROLL_ENCODER } from "../src/touchStrip/providerPanel.js";

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
    const controller = createPhysicalController({ grid, channel: () => ({ focus, control, say: vi.fn(), commandsPage: vi.fn(), answerCommand: vi.fn() }), stateChanged: changed });

    controller.handleReport(keyReport(3, true));
    controller.handleReport(keyReport(3, false));
    expect(controller.state()).toMatchObject({ mode: "cmd", focusedIdentifier: "agent-6" });
    expect(focus).toHaveBeenCalledWith("agent-6");

    controller.handleReport(keyReport(0, true));
    expect(control).toHaveBeenCalledWith("agent-6", "pause");
    expect(changed).toHaveBeenCalled();

    const resume = vi.fn();
    const pausedGrid = (): StreamDeckGrid => ({ ...grid(), agents: grid().agents.map((agent, index) => index === 6 ? { ...agent, bucket: "paused" } : agent) });
    const pausedController = createPhysicalController({ grid: pausedGrid, channel: () => ({ focus: vi.fn(), control: resume, say: vi.fn(), commandsPage: vi.fn(), answerCommand: vi.fn() }), stateChanged: vi.fn() });
    pausedController.handleReport(keyReport(3, true));
    pausedController.handleReport(keyReport(3, false));
    pausedController.handleReport(keyReport(0, true));
    expect(resume).toHaveBeenCalledWith("agent-6", "resume");
  });

  it("uses the same column-major mapping as the rendered grid at every key and offset", () => {
    for (const offset of [0, 4]) {
      for (const key of Array.from({ length: 8 }, (_, index) => index)) {
        const focus = vi.fn();
        const controller = createPhysicalController({ grid: () => grid(20), channel: () => ({ focus, control: vi.fn(), say: vi.fn(), commandsPage: vi.fn(), answerCommand: vi.fn() }), stateChanged: vi.fn() });
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
    const controller = createPhysicalController({ grid, channel: () => ({ focus: vi.fn(), control: vi.fn(), say: vi.fn(), commandsPage: vi.fn(), answerCommand: vi.fn() }), stateChanged: vi.fn() });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(2, true));
    expect(controller.state().micHeld).toBe(true);
    controller.handleReport(keyReport(2, false));
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
    // Logs opens at the live end — the far right — so the first scroll the
    // operator has anywhere to go is backwards, into history.
    expect(controller.state().chatOffset).toBe(3);
    controller.handleReport(dialTurn(0, -1));
    expect(controller.state().chatOffset).toBe(2);
    controller.handleReport(dialTurn(0, 1));
    controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 1));
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
    // Eleven events then LIVE, one transcript row each, so every key's start is
    // its own index — the shape the daemon sends.
    controller.setLogs({
      event_keys: Array.from({ length: 12 }, (_, index) => ({
        kind: index === 11 ? "live" : "event",
        text: `event-${index}`,
        start: index,
      })),
      events_max_offset: 4,
      transcript: Array.from({ length: 12 }, (_, index) => ({ kind: "event_header", body: `chat-${index}` })),
    });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(1, true));
    controller.handleReport(keyReport(1, false));
    expect(controller.state().mode).toBe("logs");
    // Opens at the right-hand end of both axes.
    expect(controller.state()).toMatchObject({ eventOffset: 4, chatOffset: 11 });
    controller.handleReport(dialTurn(3, -2));
    expect(controller.state().eventOffset).toBe(2);
    expect(controller.state().eventLines.map((event) => event.text)).toContain("event-0");
    const eventOffset = controller.state().eventOffset;
    controller.handleReport(dialTurn(0, -3));
    expect(controller.state().chatOffset).toBe(8);
    // Paging the keys and scrolling the chat are independent navigations; the
    // chat scroll must not drag the key window with it.
    expect(controller.state().eventOffset).toBe(eventOffset);
    expect(controller.state().chatHasNext).toBe(true);
    expect(changed).toHaveBeenCalled();
  });

  it("preserves both log offsets across live refreshes and clears mic on cancellation", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    const feed = (prefix: string) => ({
      event_keys: Array.from({ length: 12 }, (_, index) => ({
        kind: index === 11 ? "live" : "event",
        text: `${prefix}-${index}`,
        start: index,
      })),
      transcript: Array.from({ length: 12 }, (_, index) => ({ kind: "message", role: "system", body: `${prefix}-${index}` })),
      events_max_offset: 4,
    });
    controller.setLogs(feed("event"));
    // Enter command mode and then Logs through the production input path.
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    expect(controller.state().mode).toBe("logs");
    // Scroll *back* from the live end. A refresh preserves a deliberate
    // reading position; it re-pins only while LIVE is still the active key,
    // because following the feed is the whole meaning of LIVE.
    controller.handleReport(dialTurn(3, -1));
    controller.handleReport(dialTurn(0, -4));
    const { eventOffset, chatOffset } = controller.state();
    expect({ eventOffset, chatOffset }).toEqual({ eventOffset: 3, chatOffset: 7 });

    // A live push is a refresh, not a navigation command: it must not move a
    // reader who has deliberately scrolled back from the live end.
    controller.setLogs(feed("refresh"));
    expect(controller.state().eventOffset).toBe(eventOffset);
    expect(controller.state().chatOffset).toBe(chatOffset);

    controller.handleReport(dialButton(0));
    controller.handleReport(dialButton(0, false));
    controller.handleReport(keyReport(2, true));
    expect(controller.state().micHeld).toBe(true);
    controller.cancel();
    expect(controller.state().micHeld).toBe(false);
    controller.handleReport(keyReport(2, false));

    // Re-entering logs deliberately does *not* restore the old position: the
    // surface opens where the agent is working, every time. Restoring a reading
    // position from minutes ago would reintroduce the complaint that LIVE takes
    // you to the wrong end of the log.
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    expect(controller.state()).toMatchObject({ mode: "logs", eventOffset: 4, chatOffset: 11, selectedEvent: 11 });
  });

  /**
   * The other half of the same contract. Following the feed is what LIVE means;
   * without this the first message to arrive after opening logs would push the
   * newest row out of the window and the surface would quietly stop being live
   * while still showing LIVE as active.
   */
  it("follows the feed while LIVE is the active key", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    const feed = (rows: number) => ({
      event_keys: [
        { kind: "event", text: "origin", start: 0 },
        { kind: "live", text: "LIVE", start: rows - 1 },
      ],
      transcript: Array.from({ length: rows }, (_, index) => ({ kind: "message", role: "assistant", body: `line-${index}` })),
      events_max_offset: 0,
    });
    controller.setLogs(feed(4));
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    expect(controller.state()).toMatchObject({ mode: "logs", chatOffset: 3, selectedEvent: 1 });

    controller.setLogs(feed(7));
    expect(controller.state()).toMatchObject({ chatOffset: 6, selectedEvent: 1 });
  });

  // Flattening each event key to one display string discarded the direction
  // badge and the relative timestamp, so every log key painted an identical
  // grey INFO badge with no time.
  it("keeps each event key's direction badge, timestamp and jump target", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.setLogs({
      event_keys: [
        { kind: "event", badge: "SYSTEM", text: "Daemon reloaded", time: "12m", start: 0 },
        { kind: "event", badge: "EMIT", text: "Dependency cleared", time: "3m", start: 4 },
        { kind: "live", label: "LIVE", start: 6 },
      ],
    });
    expect(controller.state().eventLines).toEqual([
      { kind: "event", badge: "SYSTEM", text: "Daemon reloaded", time: "12m", start: 0 },
      { kind: "event", badge: "EMIT", text: "Dependency cleared", time: "3m", start: 4 },
      { kind: "live", badge: "AGENT", text: "LIVE", time: "", start: 6 },
    ]);
  });

  it("falls back to INFO for an event with no badge", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.setLogs({ event_keys: [{ kind: "event", text: "no badge here" }] });
    expect(controller.state().eventLines[0]).toEqual({ kind: "event", badge: "INFO", text: "no badge here", time: "", start: 0 });
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

    // A turn and a press are different report kinds, so scrolling the provider
    // list on knob 2 can never put the chord half down — and the chord must not
    // move the list either.
    it("coexists with the provider scroll on the same knob", () => {
      const toggleDemo = vi.fn();
      const controller = createPhysicalController({
        grid,
        channel: () => null,
        providerCount: () => 6,
        stateChanged: vi.fn(),
        toggleDemo,
      });

      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 2));
      expect(controller.state().providerOffset).toBe(2);
      expect(toggleDemo).not.toHaveBeenCalled();

      controller.handleReport(dialButtons([1, 2]));
      expect(toggleDemo).toHaveBeenCalledOnce();
      expect(controller.state().providerOffset).toBe(2);

      controller.handleReport(dialButtons([], false));
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, -1));
      expect(controller.state().providerOffset).toBe(1);
      expect(toggleDemo).toHaveBeenCalledOnce();
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
    controller.handleReport(keyReport(2, true));
    expect(controller.state().micHeld).toBe(true);
    // Logs (key 1) rises while the mic key (key 2) is still down.
    controller.handleReport(keysReport([1, 2], true));
    expect(controller.state()).toMatchObject({ mode: "logs", micHeld: false });
  });

});

describe("the Implement key", () => {
  const channelWith = (control: (identifier: string, action: "pause" | "resume" | "implement") => void) => () => ({
    focus: vi.fn(),
    control,
    say: vi.fn(),
    commandsPage: vi.fn(),
    answerCommand: vi.fn(),
  });

  /** Focuses key 0, which is `agent-0` — a queued ticket in the shared fixture. */
  const focusQueued = (controller: ReturnType<typeof createPhysicalController>): void => {
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
  };

  it("asks the channel to queue the focused agent-less ticket", () => {
    const control = vi.fn<(identifier: string, action: "pause" | "resume" | "implement") => void>();
    const controller = createPhysicalController({ grid, channel: channelWith(control), stateChanged: vi.fn() });
    focusQueued(controller);
    expect(controller.state().focusedIdentifier).toBe("agent-0");

    controller.handleReport(keyReport(7, true));
    expect(control).toHaveBeenCalledWith("agent-0", "implement");
    expect(controller.state().implementQueued).toBe(true);
  });

  it("does nothing on the last key for a ticket an agent already holds", () => {
    const control = vi.fn<(identifier: string, action: "pause" | "resume" | "implement") => void>();
    const controller = createPhysicalController({ grid, channel: channelWith(control), stateChanged: vi.fn() });
    // Key 3 is `agent-6`, the fixture's running agent.
    controller.handleReport(keyReport(3, true));
    controller.handleReport(keyReport(3, false));
    controller.handleReport(keyReport(7, true));
    expect(control).not.toHaveBeenCalled();
    expect(controller.state().implementQueued).toBe(false);
  });

  // The surface paints no Pause key for a ticket with no agent, so a press
  // there must not send the action the missing key would have sent.
  it("sends no pause for a ticket with no agent", () => {
    const control = vi.fn<(identifier: string, action: "pause" | "resume" | "implement") => void>();
    const controller = createPhysicalController({ grid, channel: channelWith(control), stateChanged: vi.fn() });
    focusQueued(controller);
    controller.handleReport(keyReport(0, true));
    expect(control).not.toHaveBeenCalled();
  });

  it("retires the QUEUED label on the next grid push", () => {
    const controller = createPhysicalController({ grid, channel: channelWith(vi.fn<(identifier: string, action: "pause" | "resume" | "implement") => void>()), stateChanged: vi.fn() });
    focusQueued(controller);
    controller.handleReport(keyReport(7, true));
    expect(controller.state().implementQueued).toBe(true);

    controller.gridChanged();
    expect(controller.state().implementQueued).toBe(false);
  });
});

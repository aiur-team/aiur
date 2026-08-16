import { describe, expect, it, vi } from "vitest";
import { createPhysicalController } from "../src/controller.js";
import type { StreamDeckGrid } from "../src/channel.js";
import { dialButton, dialButtons, dialTurn, keyReport, keysReport } from "./support/deckReports.js";
import { CHAT_WINDOW_ROWS } from "../src/touchStrip/chatLog.js";
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
    controller.handleReport(keyReport(2, true));
    controller.handleReport(keyReport(2, false));
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
    controller.handleReport(keyReport(3, true));
    expect(controller.state().micHeld).toBe(true);
    controller.cancel();
    expect(controller.state().micHeld).toBe(false);
    controller.handleReport(keyReport(3, false));

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

  describe("jump to the transcript position an event was published at", () => {
    /**
     * Three bus events, flattened the way the daemon flattens them now: oldest
     * first, each header immediately followed by that event's own entries. The
     * first event is the origin anchor every projection synthesises, which is
     * what guarantees offset 0 belongs to a key.
     */
    const transcript = [
      { kind: "event_header", badge: "INFO", body: "Ticket opened", label: "Ticket opened", timestamp: "2026-08-13T02:51:00Z" },
      { kind: "message", role: "system", body: "workspace ready" },
      { kind: "message", role: "system", body: "settled" },
      { kind: "event_header", badge: "AGENT", body: "brainstorm -> plan", label: "Phase change", timestamp: "2026-08-13T02:57:00Z" },
      { kind: "message", role: "assistant", body: "rebasing" },
      { kind: "event_header", badge: "EMIT", body: "PR #1904 opened", label: "PR opened", timestamp: "2026-08-13T03:00:00Z" },
      { kind: "message", role: "assistant", body: "unblocking" },
      { kind: "diff", path: "lib/a.ex", additions: 3, deletions: 1, line: "+  ok" },
      { kind: "diff_line", sign: "+", text: "  ok" },
    ];
    // LIVE is last, and every key carries its own jump target.
    const eventKeys = [
      { kind: "event", badge: "INFO", text: "Ticket opened", time: "9m", start: 0 },
      { kind: "event", badge: "AGENT", text: "Phase change", time: "3m", start: 3 },
      { kind: "event", badge: "EMIT", text: "PR opened", time: "now", start: 5 },
      { kind: "live", label: "LIVE", start: 8 },
    ];
    const LIVE_KEY = 3;

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
      for (const [key, start] of [[0, 0], [1, 3], [2, 5]] as const) {
        controller.handleReport(keyReport(key, true));
        controller.handleReport(keyReport(key, false));
        expect(controller.state().chatOffset).toBe(start);
        expect(controller.state().selectedEvent).toBe(key);
        // The header is in view. It is only the *top* row while five rows still
        // fit below it; nearer the end the window stops and the header moves
        // down inside it rather than dragging blank rows into view.
        expect(controller.state().transcriptRows).toContainEqual(
          expect.objectContaining({ kind: "event_header", label: eventKeys[key].text }),
        );
      }
    });

    /**
     * The bug report: LIVE took the operator to the very top — the oldest entry
     * — instead of to where the agent is working. Oldest is now the far left
     * and LIVE is the far right, so LIVE lands on the newest row.
     */
    it("jumps to the newest entry from the LIVE key, not the oldest", () => {
      const controller = inLogs();
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      expect(controller.state().chatOffset).toBe(0);
      controller.handleReport(keyReport(LIVE_KEY, true));
      controller.handleReport(keyReport(LIVE_KEY, false));
      expect(controller.state().chatOffset).toBe(transcript.length - 1);
      // The position is the last row, but the painted window stops at the end
      // rather than showing that row alone above four blank ones.
      expect(controller.state().transcriptRows).toHaveLength(CHAT_WINDOW_ROWS);
      expect(controller.state().transcriptRows.at(-1)).toMatchObject({ kind: "diff_line", sign: "+", text: "  ok" });
    });

    /**
     * Selection is mutually exclusive: pressing an event makes it active and
     * LIVE inactive, and returning to LIVE reverses it. Exactly one key is
     * active at any moment, which is what the operator could not tell before.
     */
    it("makes exactly one of LIVE and an event key active at a time", () => {
      const controller = inLogs();
      expect(controller.state().selectedEvent).toBe(LIVE_KEY);
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
      expect(controller.state().selectedEvent).toBe(1);
      controller.handleReport(keyReport(LIVE_KEY, true));
      controller.handleReport(keyReport(LIVE_KEY, false));
      expect(controller.state().selectedEvent).toBe(LIVE_KEY);
    });

    // The key window and the event list are different index spaces; reading the
    // press as a bare key index jumps to the wrong event after a page.
    it("jumps to the event under the key after the window is paged", () => {
      const controller = inLogs({ event_keys: eventKeys, transcript, events_max_offset: 2 });
      controller.handleReport(dialTurn(3, -1));
      expect(controller.state().eventOffset).toBe(1);
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      expect(controller.state().chatOffset).toBe(3);
    });

    it("keeps dial A scrolling from wherever the jump landed", () => {
      const controller = inLogs();
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
      controller.handleReport(dialTurn(0, 1));
      expect(controller.state().chatOffset).toBe(4);
      controller.handleReport(dialTurn(0, -1));
      expect(controller.state().chatOffset).toBe(3);
    });

    it("ignores a press on a slot with no event", () => {
      const controller = inLogs();
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
      const before = controller.state().chatOffset;
      controller.handleReport(keyReport(7, true));
      controller.handleReport(keyReport(7, false));
      expect(controller.state().chatOffset).toBe(before);
    });

    // A diff carries no `line` and no `body`; collapsing rows to one display
    // string printed the literal "[INFO]" for every one of them.
    it("keeps each transcript row's shape, including real diff lines", () => {
      const controller = inLogs();
      controller.handleReport(keyReport(LIVE_KEY, true));
      controller.handleReport(keyReport(LIVE_KEY, false));
      const rows = controller.state().transcriptRows;
      expect(rows[rows.length - 2]).toEqual({
        kind: "diff",
        path: "lib/a.ex",
        additions: 3,
        deletions: 1,
        line: "+  ok",
      });
      expect(rows[rows.length - 1]).toEqual({ kind: "diff_line", sign: "+", text: "  ok" });
    });

    it("highlights the event key that was pressed", () => {
      const controller = inLogs();
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
      expect(controller.state().selectedEvent).toBe(1);
    });

    // The other direction of the same tie: scrolling the transcript with dial A
    // moves the highlight to whichever event the reader has scrolled into,
    // without the operator touching a key.
    it("highlights the event the transcript has been scrolled into", () => {
      const controller = inLogs();
      controller.handleReport(dialTurn(0, -99));
      expect(controller.state().chatOffset).toBe(0);
      expect(controller.state().selectedEvent).toBe(0);
      controller.handleReport(dialTurn(0, 3));
      expect(controller.state().selectedEvent).toBe(1);
      controller.handleReport(dialTurn(0, 2));
      expect(controller.state().selectedEvent).toBe(2);
      controller.handleReport(dialTurn(0, 3));
      expect(controller.state().selectedEvent).toBe(LIVE_KEY);
    });

    // A highlight on a key the operator has paged away from looks like the
    // highlight is broken, so the key window follows the selection.
    it("pages the event keys so the highlighted key stays on screen", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      const events = Array.from({ length: 14 }, (_, index) => ({ kind: "event", badge: "INFO", text: `event-${index}`, start: index }));
      // One header per transcript row, so every row is its own event.
      controller.setLogs({
        event_keys: [...events, { kind: "live", label: "LIVE", start: 14 }],
        transcript: Array.from({ length: 15 }, (_, index) => ({ kind: "event_header", badge: "INFO", body: `header-${index}`, label: `header-${index}`, timestamp: null })),
        events_max_offset: 7,
      });
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      controller.handleReport(keyReport(2, true));
      controller.handleReport(keyReport(2, false));
      expect(controller.state().eventOffset).toBe(7);
      controller.handleReport(dialTurn(0, -13));
      expect(controller.state().selectedEvent).toBe(1);
      expect(controller.state().eventOffset).toBe(1);
      // Scrolling forward moves the window only as far as it must.
      controller.handleReport(dialTurn(0, 9));
      expect(controller.state()).toMatchObject({ selectedEvent: 10, eventOffset: 3 });
    });

    // The event window and the chat are two independent navigations. Chasing
    // the selection on a dial-3 move pinned the window to the selected key, so
    // every detent past the first did nothing and the far end of a long feed
    // was unreachable.
    it("lets dial 3 page the event window away from the highlighted key", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      const events = Array.from({ length: 30 }, (_, index) => ({ kind: "event", badge: "INFO", text: `event-${index}`, start: index * 2 }));
      controller.setLogs({
        event_keys: [...events, { kind: "live", label: "LIVE", start: 59 }],
        transcript: events.flatMap((_event, index) => [
          { kind: "event_header", badge: "INFO", body: `header-${index}`, label: `header-${index}`, timestamp: null },
          { kind: "message", role: "system", body: `entry-${index}` },
        ]),
        events_max_offset: 23,
      });
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      controller.handleReport(keyReport(2, true));
      controller.handleReport(keyReport(2, false));
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      const selected = controller.state().selectedEvent;

      controller.handleReport(dialTurn(3, -5));
      expect(controller.state()).toMatchObject({ eventOffset: 18, selectedEvent: selected });
      // The press pages a whole window, again without the chat dragging it back
      // to the neighbourhood of the selected key.
      controller.handleReport(dialButton(3));
      controller.handleReport(dialButton(3, false));
      expect(controller.state().eventOffset).not.toBe(18);
      expect(controller.state().selectedEvent).toBe(selected);
    });

    // Every row must be reachable as a window start, including the last few.
    it("reaches a header in the last rows of the transcript", () => {
      const controller = inLogs();
      const last = transcript.length - 1;
      controller.handleReport(keyReport(2, true));
      controller.handleReport(keyReport(2, false));
      expect(controller.state().chatOffset).toBe(5);
      expect(controller.state().selectedEvent).toBe(2);
      controller.handleReport(dialTurn(0, 99));
      expect(controller.state().chatOffset).toBe(last);
      expect(controller.state().transcriptRows).toHaveLength(CHAT_WINDOW_ROWS);
      expect(controller.state().transcriptRows.at(-1)).toMatchObject({ kind: "diff_line", sign: "+", text: "  ok" });
    });

    /**
     * The origin anchor means no offset is ever above every header. A feed that
     * omitted it would leave rows nothing could reach; fall back to the first
     * key rather than to no selection, because "no key is active" is a state
     * this surface no longer has.
     */
    it("keeps a key active even for rows above the first header", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs({
        event_keys: eventKeys.map((key) => ({ ...key, start: (key.start as number) + 1 })),
        transcript: [{ kind: "message", role: "system", body: "orphan" }, ...transcript],
        events_max_offset: 2,
      });
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      controller.handleReport(keyReport(2, true));
      controller.handleReport(keyReport(2, false));
      controller.handleReport(dialTurn(0, -99));
      expect(controller.state()).toMatchObject({ selectedEvent: 0, chatOffset: 0 });
    });

    it("opens the surface at the live end when the server sends no offset", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs({ event_keys: eventKeys, transcript });
      expect(controller.state().chatOffset).toBe(transcript.length - 1);
      expect(controller.state().selectedEvent).toBe(LIVE_KEY);
    });

    it("repaints the transcript window when logs is re-entered", () => {
      const controller = inLogs();
      controller.handleReport(dialButton(0));
      controller.handleReport(dialButton(0, false));
      expect(controller.state()).toMatchObject({ mode: "cmd", transcriptRows: [] });
      controller.handleReport(dialButton(3));
      controller.handleReport(dialButton(3, false));
      expect(controller.state().mode).toBe("logs");
      expect(controller.state().transcriptRows.length).toBeGreaterThan(0);
    });

    /**
     * The surface opens at the live end, so a test that wants to read the whole
     * normalised history has to scroll back to the beginning first — the same
     * thing the operator does.
     */
    const fromTheStart = (logs: Parameters<ReturnType<typeof createPhysicalController>["setLogs"]>[0]) => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs(logs);
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      controller.handleReport(dialButton(3));
      controller.handleReport(dialButton(3, false));
      controller.handleReport(dialTurn(0, -99));
      return controller;
    };

    it("keeps an event header's badge, body, label and timestamp", () => {
      const controller = fromTheStart({ transcript: [transcript[0], { kind: "event_header", timestamp: "" }] });
      expect(controller.state().transcriptRows).toEqual([
        { kind: "event_header", badge: "INFO", body: "Ticket opened", label: "Ticket opened", timestamp: "2026-08-13T02:51:00Z" },
        { kind: "event_header", badge: "INFO", body: "", label: "", timestamp: null },
      ]);
    });

    it("normalises a diff with no lines and an unknown row shape", () => {
      const controller = fromTheStart({
        transcript: [{ kind: "diff", path: "lib/b.ex" }, { kind: "mystery", body: "hello" }, { body: "no kind" }],
      });
      expect(controller.state().transcriptRows).toEqual([
        { kind: "diff", path: "lib/b.ex", additions: 0, deletions: 0, line: null },
        { kind: "message", role: "system", body: "hello", tool: null },
        { kind: "message", role: "system", body: "no kind", tool: null },
      ]);
    });

    /**
     * A sign the feed did not send is context, not a colour choice. Letting an
     * arbitrary string through would let the payload pick the added/removed
     * tint, which is the one thing a diff row's colour is supposed to mean.
     */
    it("treats any diff sign that is not + or - as context", () => {
      const controller = fromTheStart({
        transcript: [
          { kind: "diff_line", sign: "?", text: "odd" },
          { kind: "diff_line", sign: "-", text: "gone" },
          { kind: "diff_line" },
        ],
      });
      expect(controller.state().transcriptRows).toEqual([
        { kind: "diff_line", sign: " ", text: "odd" },
        { kind: "diff_line", sign: "-", text: "gone" },
        { kind: "diff_line", sign: " ", text: "" },
      ]);
    });

    it("carries a tool name through, and reads its absence as absence", () => {
      const controller = fromTheStart({
        transcript: [
          { kind: "message", role: "tool", body: "src/a.ts", tool: "edit" },
          { kind: "message", role: "tool", body: "src/b.ts", tool: "" },
        ],
      });
      expect(controller.state().transcriptRows[0]).toMatchObject({ tool: "edit" });
      expect(controller.state().transcriptRows[1]).toMatchObject({ tool: null });
    });

    /**
     * Live typing. The daemon sends completed strings, so the reveal is an
     * emulation — but it must only run at the live end, only for a genuinely
     * new body, and it must finish at the whole string rather than looping.
     */
    describe("live typing", () => {
      const typing = (body: string) => ({
        event_keys: [{ kind: "event", badge: "INFO", text: "origin", start: 0 }, { kind: "live", label: "LIVE", start: 1 }],
        transcript: [
          { kind: "event_header", badge: "INFO", body: "Ticket opened", label: "Ticket opened", timestamp: null },
          { kind: "message", role: "assistant", body },
        ],
      });
      const openLogs = () => {
        const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
        controller.setLogs(typing("first"));
        controller.handleReport(keyReport(0, true));
        controller.handleReport(keyReport(0, false));
        controller.handleReport(dialButton(3));
        controller.handleReport(dialButton(3, false));
        return controller;
      };
      const newest = (controller: ReturnType<typeof createPhysicalController>) => {
        const rows = controller.state().transcriptRows;
        return String((rows[rows.length - 1] as { body?: string }).body ?? "");
      };

      it("does not type out the transcript that was already there", () => {
        const controller = openLogs();
        expect(newest(controller)).toBe("first");
        expect(controller.tickTyping()).toBe(false);
      });

      it("reveals a newly arrived message a few characters at a time", () => {
        const controller = openLogs();
        controller.setLogs(typing("a much longer sentence than the first one"));
        expect(newest(controller).length).toBeLessThan("a much longer sentence than the first one".length);
        const partial = newest(controller).length;
        expect(controller.tickTyping()).toBe(true);
        expect(newest(controller).length).toBeGreaterThan(partial);
      });

      it("finishes on the whole string and then stops", () => {
        const controller = openLogs();
        controller.setLogs(typing("a much longer sentence than the first one"));
        let guard = 0;
        while (controller.tickTyping() && guard < 100) guard += 1;
        expect(newest(controller)).toBe("a much longer sentence than the first one");
        expect(controller.tickTyping()).toBe(false);
      });

      // Reading history is not watching the agent work. Animating an old row
      // would date it wrongly.
      it("does not animate while the operator has scrolled away from live", () => {
        const controller = openLogs();
        controller.handleReport(dialTurn(0, -1));
        controller.setLogs(typing("a much longer sentence than the first one"));
        expect(controller.tickTyping()).toBe(false);
      });

      it("is inert outside logs mode", () => {
        const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
        controller.setLogs(typing("first"));
        expect(controller.tickTyping()).toBe(false);
      });
    });
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

  describe("provider scroll on knob 2", () => {
    const scrolling = (providerCount: number, stateChanged = vi.fn()) =>
      createPhysicalController({ grid, channel: () => null, providerCount: () => providerCount, stateChanged });

    // Same detent lesson as the grid columns: the offset steps from the report's
    // own ticks, so one click is one provider rather than a fraction of one.
    it("moves the list exactly one provider per detent", () => {
      const controller = scrolling(6);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 1));
      expect(controller.state().providerOffset).toBe(1);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 1));
      expect(controller.state().providerOffset).toBe(2);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, -1));
      expect(controller.state().providerOffset).toBe(1);
    });

    it("applies a multi-detent report in one step", () => {
      const controller = scrolling(9);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 3));
      expect(controller.state().providerOffset).toBe(3);
    });

    // Unclamped, a long spin would have to be unwound click for click before the
    // list moved again.
    it("clamps at both ends of the provider list", () => {
      const controller = scrolling(5);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 99));
      expect(controller.state().providerOffset).toBe(2);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, -99));
      expect(controller.state().providerOffset).toBe(0);
    });

    it("does not move when every provider already fits", () => {
      const controller = scrolling(3);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 2));
      expect(controller.state().providerOffset).toBe(0);
    });

    // The provider panel belongs to the grid strip. Scrolling it from cmd or
    // logs would move something the operator cannot see.
    it("is inert outside the grid", () => {
      const controller = scrolling(6);
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      expect(controller.state().mode).toBe("cmd");
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 2));
      expect(controller.state().providerOffset).toBe(0);
    });

    it("cannot scroll on a host with no usage feed", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 2));
      expect(controller.state().providerOffset).toBe(0);
    });

    // The strip only repaints on a state change, so a scroll that does not
    // publish is a scroll the operator never sees.
    it("publishes the new offset so the strip repaints", () => {
      const changed = vi.fn();
      const controller = scrolling(6, changed);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 1));
      expect(changed).toHaveBeenCalledWith(expect.objectContaining({ providerOffset: 1 }));
    });

    // The panel clamps again when it paints, so a stale stored offset does not
    // show a wrong window — it eats the next detent, and the knob looks dead at
    // exactly the moment the fleet changed under the operator. The demo chord
    // on this same knob swaps the provider set, so this is a normal path.
    it("keeps moving on the first detent after the provider list shrinks", () => {
      let providers = 9;
      const controller = createPhysicalController({
        grid,
        channel: () => null,
        providerCount: () => providers,
        stateChanged: vi.fn(),
      });
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 6));
      expect(controller.state().providerOffset).toBe(6);

      providers = 5;
      // The painted window is now clamped to 2; one detent up must land on 1,
      // not back on the row already showing.
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, -1));
      expect(controller.state().providerOffset).toBe(1);
    });

    it("leaves the other knobs' offsets alone", () => {
      const controller = scrolling(6);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 2));
      expect(controller.state()).toMatchObject({ columnOffset: 0, eventOffset: 0, chatOffset: 0 });
    });
  });

  /**
   * The key window opens at the newest end and dial D scrolls back from there.
   *
   * It no longer adopts the server's `events_offset`. Where the operator is
   * reading is a client-side position — the daemon flushes several times a
   * second and has no idea the deck is even on this surface — and the one
   * position that is always right on arrival is "the end", because that is
   * where the agent is.
   */
  it("opens the key window at the newest end and pages back from there", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.setLogs({
      event_keys: Array.from({ length: 20 }, (_, index) => ({
        kind: index === 19 ? "live" : "event",
        text: `event-${index}`,
        start: index,
      })),
      events_offset: 8,
      events_max_offset: 12,
      transcript: Array.from({ length: 20 }, (_, index) => ({ kind: "event_header", body: `chat-${index}` })),
    });
    expect(controller.state().eventOffset).toBe(12);
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    controller.handleReport(dialTurn(3, -1));
    expect(controller.state().eventOffset).toBe(11);
  });
});

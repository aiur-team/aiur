import { describe, expect, it, vi } from "vitest";
import { createPhysicalController } from "../src/controller.js";
import type { StreamDeckGrid } from "../src/channel.js";
import { dialButton, dialTurn, keyReport } from "./support/deckReports.js";
import { CHAT_WINDOW_ROWS } from "../src/touchStrip/chatLog.js";

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
    // LIVE is pinned to the bottom-right physical key (index 7), while its
    // absolute position in the event list is the last index.
    const LIVE_KEY = 7;
    const LIVE_SELECTION = eventKeys.length - 1;

    /** A controller sitting on the logs surface with the fixture feed loaded. */
    const inLogs = (logs: Parameters<ReturnType<typeof createPhysicalController>["setLogs"]>[0] = { event_keys: eventKeys, transcript }) => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs(logs);
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
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
      expect(controller.state().selectedEvent).toBe(LIVE_SELECTION);
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
      expect(controller.state().selectedEvent).toBe(1);
      controller.handleReport(keyReport(LIVE_KEY, true));
      controller.handleReport(keyReport(LIVE_KEY, false));
      expect(controller.state().selectedEvent).toBe(LIVE_SELECTION);
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
      // The fixture has three events + LIVE, so keys 3-6 are empty event slots;
      // LIVE is pinned at key 7, which is not an empty slot.
      controller.handleReport(keyReport(3, true));
      controller.handleReport(keyReport(3, false));
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
      expect(controller.state().selectedEvent).toBe(LIVE_SELECTION);
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
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
      expect(controller.state().eventOffset).toBe(7);
      controller.handleReport(dialTurn(0, -13));
      expect(controller.state().selectedEvent).toBe(1);
      expect(controller.state().eventOffset).toBe(1);
      // Scrolling forward moves the window only as far as it must: seven event
      // slots, so event 10 lands in the last event slot (position 6) at offset 4.
      controller.handleReport(dialTurn(0, 9));
      expect(controller.state()).toMatchObject({ selectedEvent: 10, eventOffset: 4 });
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
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
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
      controller.handleReport(keyReport(1, true));
      controller.handleReport(keyReport(1, false));
      controller.handleReport(dialTurn(0, -99));
      expect(controller.state()).toMatchObject({ selectedEvent: 0, chatOffset: 0 });
    });

    it("opens the surface at the live end when the server sends no offset", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.setLogs({ event_keys: eventKeys, transcript });
      expect(controller.state().chatOffset).toBe(transcript.length - 1);
      // Opening selects LIVE — its absolute position in the event list, not the
      // pinned physical key index.
      expect(controller.state().selectedEvent).toBe(LIVE_SELECTION);
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
        { kind: "message", role: "system", body: "hello", tool: null, rowKind: "logs", glyph: null },
        { kind: "message", role: "system", body: "no kind", tool: null, rowKind: "logs", glyph: null },
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
});

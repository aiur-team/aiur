/** Grid paging and the logs surface: offsets, the transcript window, the typing reveal. */
import { EVENTS_PER_PAGE, maxColumnOffset } from "../dial.js";
import { type StreamDeckLogs, type TranscriptRow } from "../channel.js";
import { CHAT_WINDOW_ROWS, ensureEventVisible, selectedKeyAtOffset } from "../touchStrip/chatLog.js";
import { createTypewriter } from "../touchStrip/typewriter.js";
import {
  type EventKey,
  toTranscriptRow,
  toEventKey,
  type ControllerCore,
} from "./state.js";

import type { VoiceSettings } from "./voice-settings.js";

export const createGridLogs = (core: ControllerCore, { stopVoice }: Pick<VoiceSettings, "stopVoice">) => {
  const { options, publish } = core;
  let transcriptHistory: readonly TranscriptRow[] = [];
  /**
   * Jump target for each key, in key order, taken from the feed's own `start`
   * field. The last entry is LIVE's, which is the newest row.
   */
  let eventStarts: readonly number[] = [];
  let eventHistory: readonly EventKey[] = [];
  let eventMaxOffset = 0;
  let chatMaxOffset = 0;
  /** True once a logs payload has been applied, so the first one can open at the end. */
  let logsSeen = false;
  const typewriter = createTypewriter();

  /**
   * The five rows painted for a reading position.
   *
   * The position and the window are deliberately different things. Every row
   * has to be addressable as a position, because an event whose header lands in
   * the last few rows — one published after the agent's last word, which is
   * most of them — must still be somewhere a key press can go. But a window
   * that literally started at the last row would paint one line above four
   * blank ones, which is not what "scroll fully right" looks like in any chat
   * client. So the window stops at the end while the position keeps going,
   * exactly as a scroll view does.
   */
  const visibleRows = (offset: number): readonly TranscriptRow[] => {
    const rows = typewriter.render(transcriptHistory);
    const start = Math.max(0, Math.min(offset, rows.length - CHAT_WINDOW_ROWS));
    return rows.slice(start, start + CHAT_WINDOW_ROWS);
  };

  /** Drops every position that is an index into one agent's transcript. */
  const forgetLogs = (): void => {
    transcriptHistory = [];
    eventHistory = [];
    eventStarts = [];
    eventMaxOffset = 0;
    chatMaxOffset = 0;
    logsSeen = false;
    typewriter.forget();
  };

  const setGridOffset = (value: number): void => {
    const grid = options.grid();
    const offset = Math.max(0, Math.min(value, maxColumnOffset(grid.total)));
    publish({ ...core.state, columnOffset: offset });
  };

  /**
   * Publishes both logs offsets, the visible transcript window, and which event
   * that window is sitting in.
   *
   * The selection is derived from the chat offset rather than remembered from
   * the last key press, which is what makes the highlight bidirectional: a
   * press moves the offset and the selection follows, and so does a scroll.
   *
   * `follow` decides whether the event key window chases that selection. It
   * must be off whenever the operator is moving the event window *itself* —
   * knob 3 and its press — or the chase immediately drags the window back to
   * the selected key and the knob does nothing at all. It is on for the chat
   * scroll and the event-key jumps, where a highlight on a key the operator
   * cannot see would look like the highlight is broken.
   */
  const setLogsOffsets = (eventOffset: number, chatOffset: number, follow = true, pressed?: number): void => {
    const maxChat = chatMaxOffset;
    const boundedChat = Math.max(0, Math.min(chatOffset, maxChat));
    // A press says which key it was; only a scroll has to infer it.
    //
    // Inference alone could not tell the two apart at one particular offset: an
    // event published after the agent's last word — `ci.passed`, `pr.merged`, a
    // resolved decision, all of which arrive with no transcript under them —
    // has its header as the final row, so its jump target and LIVE's are the
    // same number. Whichever way that tie broke, one of the two keys became
    // permanently unselectable.
    const selectedEvent = pressed ?? selectedKeyAtOffset(eventStarts, boundedChat, maxChat);
    const requested = Math.max(0, Math.min(eventOffset, eventMaxOffset));
    const boundedEvent = follow && selectedEvent !== null ? ensureEventVisible(requested, selectedEvent, eventMaxOffset) : requested;
    // Typing only reads as typing at the live end of the log, on the surface
    // that shows it. `setLogs` also runs in grid and cmd mode, and arming the
    // reveal there left it primed: the operator opened logs to a blank newest
    // row that then typed out a message minutes old.
    typewriter.observe(transcriptHistory, core.state.mode === "logs" && boundedChat >= maxChat);
    publish({
      ...core.state,
      eventOffset: boundedEvent,
      chatOffset: boundedChat,
      eventLines: eventHistory,
      transcriptRows: visibleRows(boundedChat),
      eventHasPrevious: boundedEvent > 0,
      eventHasNext: boundedEvent < eventMaxOffset,
      chatHasPrevious: boundedChat > 0,
      chatHasNext: boundedChat < maxChat,
      selectedEvent,
    });
  };

  /**
   * Opens the logs surface and repaints its transcript window.
   *
   * Leaving logs clears the visible rows, so re-entering has to rebuild the
   * window from the retained history; without it the strip stayed blank until
   * the daemon happened to push again.
   */
  /**
   * Opens the logs surface at the live end.
   *
   * Entering logs used to land on offset 0, which under the old newest-first
   * flattening was the newest entry and under the current oldest-first
   * flattening would be the ticket's very first line. Either way the operator
   * opened logs to see what the agent is doing *now*, so the surface opens
   * scrolled fully right — the same place the LIVE key jumps to.
   */
  const enterLogs = (): void => {
    stopVoice();
    publish({ ...core.state, mode: "logs", micHeld: false });
    setLogsOffsets(eventMaxOffset, chatMaxOffset);
  };

  /** One key press on the logs surface: jump the transcript to that key's event. */
  const pressLogsKey = (index: number): void => {
    // Pressing a key scrolls the transcript to that key's own start. LIVE is
    // pinned to the bottom-right key and is not part of the scroll window, so
    // it is not addressable as eventOffset + index: key EVENTS_PER_PAGE (7)
    // is LIVE, the feed's last key, and keys 0-6 are the event page. Its
    // start is the newest row, so the same line of code serves both, and the
    // selection that follows is derived from where the scroll landed — which
    // is what makes exactly one of {LIVE, an event} active at a time.
    const position = index === EVENTS_PER_PAGE ? eventHistory.length - 1 : core.state.eventOffset + index;
    // An event slot that is not a real event is a padded empty key: the last
    // real event sits at `eventHistory.length - 2` (LIVE owns the last
    // index), so anything at or past LIVE's index on an event key is empty.
    if (index !== EVENTS_PER_PAGE && position >= eventHistory.length - 1) return;
    const entry = eventHistory[position];
    if (entry === undefined) return;
    setLogsOffsets(core.state.eventOffset, entry.start, true, position);
  };

  const setLogs = (logs: StreamDeckLogs): void => {
    // Deliberately not falling back to `event_keys_visible`: that is the
    // server's own eight-key slice, already offset and padded with empty
    // slots. Paging a pre-sliced list adds the client's offset a second time,
    // so a press addressed the wrong event, and each padding slot normalised
    // into a pressable key that jumped nowhere.
    eventHistory = (logs.event_keys ?? []).map(toEventKey);
    const transcript = logs.transcript ?? [];
    transcriptHistory = transcript.map(toTranscriptRow);
    eventStarts = eventHistory.map((event) => event.start);
    eventMaxOffset = typeof logs.events_max_offset === "number" ? logs.events_max_offset : Math.max(0, eventHistory.length - EVENTS_PER_PAGE - 1);
    // Every row must be reachable as a window *start*, not just visible in
    // some window. The daemon flattens newest event first, so the oldest
    // event's header is usually within the last few rows; capping the offset
    // at `length - CHAT_WINDOW_ROWS` made those headers impossible to scroll
    // to, and a jump to one landed short — mid-message, with the highlight on
    // a different key than the one pressed. The last few windows therefore
    // run off the end of the transcript and paint fewer than
    // CHAT_WINDOW_ROWS rows, which is what a scroll view is supposed to do.
    //
    // Never taken from the server's `transcript_max_offset`: how many rows
    // fit is a client render decision the server cannot know.
    const previousMax = chatMaxOffset;
    const previousStarts = eventStarts;
    const previousSelection = core.state.selectedEvent;
    const previousChat = core.state.chatOffset;
    // Every row stays addressable as a reading position, because an event
    // header in the last few rows must still be somewhere a key can jump to.
    // What is clamped is the *painted* window, not the position — see
    // `visibleRows`.
    chatMaxOffset = Math.max(0, transcriptHistory.length - 1);
    // A live logs push is a refresh, not a navigation command. Preserve the
    // operator's position while the logs surface is open — with one
    // exception: while LIVE is the active key the view follows the feed,
    // because that is the entire meaning of LIVE. Without this, the first new
    // message after opening logs would push the newest row out of the window
    // and the surface would silently stop being live.
    //
    // A first payload always follows live, even if the operator opened logs
    // before it arrived: there was no reading position to preserve.
    const following = !logsSeen || core.state.mode !== "logs" || previousChat >= previousMax;
    logsSeen = true;
    if (following) {
      setLogsOffsets(eventMaxOffset, chatMaxOffset);
      return;
    }
    // Carrying the *absolute* offset drifts. The daemon sends a sliding
    // window of the newest transcript entries, so once a ticket passes that
    // limit every new message shifts every row down one and a reader who has
    // not touched a knob scrolls forward one row per flush. Carry how far
    // into the selected event the operator was instead, and re-derive the
    // absolute offset from that event's new header — which is exactly what
    // the server does across its own refreshes.
    const anchor = previousSelection === null ? undefined : previousStarts[previousSelection];
    const into = anchor === undefined ? 0 : previousChat - anchor;
    const rebased = previousSelection === null ? previousChat : (eventStarts[previousSelection] ?? previousChat) + into;
    // `follow: false` — this branch is by definition "the operator is not
    // following the feed", so a flush must not drag the key window back onto
    // the selection. The server takes the same care in `restore_events_offset`
    // and it would be undone here.
    setLogsOffsets(core.state.eventOffset, rebased, false, previousSelection ?? undefined);
  };

  /**
   * Advances the live-typing reveal by one frame.
   *
   * Returns true when the surface owes the device another repaint. The host
   * owns the timer: the controller has no clock, which is what keeps every
   * transition in this module testable without waiting on one.
   */
  const tickTyping = (): boolean => {
    if (core.state.mode !== "logs" || !typewriter.animating()) return false;
    const more = typewriter.tick();
    // `follow: false` — a frame of the reveal changes rendered text, nothing
    // positional. Letting it re-run the chase dragged the event-key window
    // back onto the selection every 40ms, so dial D was inert for the whole
    // time the agent appeared to be typing.
    setLogsOffsets(core.state.eventOffset, core.state.chatOffset, false, core.state.selectedEvent ?? undefined);
    return more;
  };

  return {
    forgetLogs,
    setGridOffset,
    setLogsOffsets,
    enterLogs,
    pressLogsKey,
    setLogs,
    tickTyping,
    /** Read at use, never cached: both bounds move with every logs push. */
    eventMaxOffset: (): number => eventMaxOffset,
    chatMaxOffset: (): number => chatMaxOffset,
  };
};

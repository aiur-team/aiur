import { cycleEventPage, cycleWindow, maxColumnOffset } from "./dial.js";
import { decodeInputReport, risingEdges, type DeckInput } from "./input.js";
import type { StreamDeckChannel, StreamDeckGrid, StreamDeckLogs, TranscriptRow } from "./channel.js";
import { agentIndexForKey } from "./keys.js";
import { CHAT_WINDOW_ROWS, ensureEventVisible, eventKeyAtOffset } from "./touchStrip/chatLog.js";
import { maxProviderOffset, PROVIDER_SCROLL_ENCODER } from "./touchStrip/providerPanel.js";

export type ControllerMode = "grid" | "cmd" | "logs";

/**
 * One row of the log surface, kept structured all the way to the renderer.
 *
 * The daemon sends `{kind, badge, text, time}` per event key. Flattening that
 * to a single display string on arrival threw away the direction badge and the
 * relative timestamp, so every event key painted an identical grey `INFO` badge
 * and no time at all.
 */
export interface EventKey {
  /** `live` is the feed's sentinel first row, not an event. */
  readonly kind: "live" | "event";
  /** Direction badge: EMIT, CONSUME, INFO, AGENT or SYSTEM. */
  readonly badge: string;
  readonly text: string;
  /** Relative timestamp such as "3m"; empty when the feed omits one. */
  readonly time: string;
}

const asString = (value: unknown, fallback = ""): string => (typeof value === "string" ? value : fallback);
const asNumber = (value: unknown): number => (typeof value === "number" && Number.isFinite(value) ? value : 0);
/** Empty strings are absent values here: the daemon omits, rather than blanks, a missing diff line. */
const asText = (value: unknown): string | null => (typeof value === "string" && value !== "" ? value : null);

/** Normalises one server transcript row into a {@link TranscriptRow}. */
const toTranscriptRow = (entry: Readonly<Record<string, unknown>>): TranscriptRow => {
  if (entry.kind === "event_header") {
    return {
      kind: "event_header",
      badge: asString(entry.badge, "INFO"),
      body: asString(entry.body),
      timestamp: asText(entry.timestamp),
    };
  }
  if (entry.kind === "diff") {
    return {
      kind: "diff",
      path: asString(entry.path, "changed file"),
      additions: asNumber(entry.additions),
      deletions: asNumber(entry.deletions),
      line: asText(entry.line),
    };
  }
  // Anything else is treated as a message rather than dropped: a row the
  // renderer cannot classify still has to hold its position, because every
  // position after it is a jump target the log keys address by index.
  // `system` rather than `agent`: it is the daemon's own default for an entry
  // with no role, and painting an unattributed row in the agent's colour claims
  // the agent said something it did not.
  return { kind: "message", role: asString(entry.role, "system"), body: asString(entry.body, asString(entry.line)) };
};

/** Normalises one server event-key payload into an {@link EventKey}. */
const toEventKey = (event: Readonly<Record<string, unknown>>): EventKey =>
  event.kind === "live"
    ? { kind: "live", badge: "LIVE", text: asString(event.label, "LIVE"), time: "" }
    : {
        kind: "event",
        badge: asString(event.badge, "INFO"),
        text: asString(event.text, asString(event.label, "EVENT")),
        time: asString(event.time),
      };

export interface ControllerState {
  readonly mode: ControllerMode;
  readonly focusedIdentifier: string | null;
  readonly columnOffset: number;
  /** First provider row the grid strip's merged provider panel shows. */
  readonly providerOffset: number;
  readonly eventOffset: number;
  readonly chatOffset: number;
  readonly transcriptRows: readonly TranscriptRow[];
  readonly eventLines: readonly EventKey[];
  readonly eventHasPrevious: boolean;
  readonly eventHasNext: boolean;
  readonly chatHasPrevious: boolean;
  readonly chatHasNext: boolean;
  /** Position in `eventLines` the transcript is currently showing, or null. */
  readonly selectedEvent: number | null;
  readonly micHeld: boolean;
}

export interface PhysicalControllerOptions {
  grid(): StreamDeckGrid;
  channel(): Pick<StreamDeckChannel, "focus" | "control"> | null;
  /**
   * Providers the daemon currently reports, which is what bounds the provider
   * scroll. Absent for hosts with no usage feed, where the list cannot scroll.
   */
  providerCount?(): number;
  stateChanged(state: ControllerState): void;
  /** Invoked when the demo chord is held; absent when the host has no demo. */
  toggleDemo?(): void;
}

/**
 * Encoder buttons that toggle demo mode when pressed together: the middle two
 * knobs.
 *
 * Knobs rather than keys, and specifically these two, because their presses are
 * the only controls on the deck with no meaning of their own — dial A presses
 * for back and dial D cycles the window, while B and C are free. So the chord
 * cannot shadow a real action in any mode, and cannot be hit while paging.
 * Knob B turning the provider list does not change that: a turn and a press are
 * separate report kinds, so scrolling never puts the chord halfway down.
 * Holding it also returns the surface to the grid: swapping the data source
 * underneath a focused agent would leave the command screen describing a ticket
 * that is no longer in the fleet being shown.
 */
export const DEMO_CHORD: readonly number[] = [1, 2];

const initialState: ControllerState = {
  mode: "grid",
  focusedIdentifier: null,
  columnOffset: 0,
  providerOffset: 0,
  eventOffset: 0,
  chatOffset: 0,
  transcriptRows: [],
  eventLines: [],
  eventHasPrevious: false,
  eventHasNext: false,
  chatHasPrevious: false,
  chatHasNext: false,
  selectedEvent: null,
  micHeld: false,
};

const agentAt = (grid: StreamDeckGrid, offset: number, key: number): Readonly<Record<string, unknown>> | undefined =>
  grid.agents[agentIndexForKey(offset, key)];

const identifierOf = (agent: Readonly<Record<string, unknown>> | undefined): string | null =>
  typeof agent?.identifier === "string" ? agent.identifier : null;

/**
 * Production input/state composition for the direct-HID surface. It owns only
 * navigation and delegates fleet mutations to the authenticated channel. The
 * renderer remains the single source of pixels, and every state change calls
 * `stateChanged`, so physical input is immediately visible on the deck.
 */
export const createPhysicalController = (options: PhysicalControllerOptions) => {
  let state = initialState;
  let pressed = new Set<string>();
  let chordActive = false;
  let transcriptHistory: readonly TranscriptRow[] = [];
  /**
   * Index in the flattened transcript where each event's entries begin.
   *
   * The daemon flattens the transcript as an `event_header` followed by that
   * event's chat entries, newest event first, so the header positions are the
   * jump targets for the log keys — no extra wire message is needed to find
   * them. Position `n` here belongs to event key `n + 1`, because key 0 is the
   * LIVE row rather than an event.
   */
  let eventStarts: readonly number[] = [];
  let eventHistory: readonly EventKey[] = [];
  let eventMaxOffset = 0;
  let chatMaxOffset = 0;

  const publish = (next: ControllerState): void => {
    if (JSON.stringify(next) === JSON.stringify(state)) return;
    state = next;
    options.stateChanged(state);
  };

  const focusedAgent = (): Readonly<Record<string, unknown>> | undefined =>
    options.grid().agents.find((agent) => String(agent.identifier) === state.focusedIdentifier);

  const setGridOffset = (value: number): void => {
    const grid = options.grid();
    const offset = Math.max(0, Math.min(value, maxColumnOffset(grid.total)));
    publish({ ...state, columnOffset: offset });
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
  const setLogsOffsets = (eventOffset: number, chatOffset: number, follow = true): void => {
    const maxChat = chatMaxOffset;
    const boundedChat = Math.max(0, Math.min(chatOffset, maxChat));
    const selectedEvent = eventKeyAtOffset(eventStarts, boundedChat);
    const requested = Math.max(0, Math.min(eventOffset, eventMaxOffset));
    const boundedEvent = follow && selectedEvent !== null ? ensureEventVisible(requested, selectedEvent, eventMaxOffset) : requested;
    publish({
      ...state,
      eventOffset: boundedEvent,
      chatOffset: boundedChat,
      eventLines: eventHistory,
      transcriptRows: transcriptHistory.slice(boundedChat, boundedChat + CHAT_WINDOW_ROWS),
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
  const enterLogs = (): void => {
    publish({ ...state, mode: "logs", micHeld: false });
    setLogsOffsets(state.eventOffset, state.chatOffset);
  };

  const back = (): void => {
    if (state.mode === "logs") publish({ ...state, mode: "cmd", transcriptRows: [], micHeld: false });
    else if (state.mode === "cmd") publish({ ...state, mode: "grid", focusedIdentifier: null, micHeld: false });
  };

  const pressKey = (index: number): void => {
    const grid = options.grid();
    if (state.mode === "logs") {
      // Pressing an event key scrolls the transcript to where that event
      // begins; the LIVE row jumps to the newest entry. Dial A still scrolls
      // freely from wherever the jump landed.
      const position = state.eventOffset + index;
      const entry = eventHistory[position];
      if (entry === undefined) return;
      if (entry.kind === "live") {
        // LIVE is a jump to the newest entry, not an event. The highlight that
        // follows lands on the newest *event* key, because that is the event
        // the transcript is now showing — LIVE itself is never "the event the
        // strip is reading".
        setLogsOffsets(state.eventOffset, 0);
        return;
      }
      // An event with no header in the transcript has nowhere to scroll to, so
      // the press is inert rather than silently jumping to the newest entry —
      // which is the LIVE key's job and would look like the wrong key fired.
      const target = eventStarts[position - 1];
      if (target === undefined) return;
      setLogsOffsets(state.eventOffset, target);
      return;
    }
    if (state.mode === "grid") {
      const identifier = identifierOf(agentAt(grid, state.columnOffset, index));
      if (identifier !== null) {
        options.channel()?.focus(identifier);
        publish({ ...state, mode: "cmd", focusedIdentifier: identifier });
      }
      return;
    }
    if (state.mode === "cmd") {
      const agent = focusedAgent();
      const identifier = state.focusedIdentifier;
      if (identifier === null || agent === undefined) return;
      if (index === 0) {
        // Anything not already paused can be paused. Restricting this to the
        // `running` bucket left the key inert for an alert or stuck agent —
        // exactly the states an operator most wants to halt.
        options.channel()?.control(identifier, agent.bucket === "paused" ? "resume" : "pause");
      } else if (index === 1) {
        options.channel()?.control(identifier, agent.priority === true ? "deprioritize" : "prioritize");
      } else if (index === 2) {
        enterLogs();
      } else if (index === 3) {
        publish({ ...state, micHeld: true });
      }
    }
  };

  const releaseMic = (): void => {
    if (state.micHeld) publish({ ...state, micHeld: false });
  };

  /**
   * One detent moves the list exactly one position.
   *
   * This used to route a turn through the mock's 0-100 knob value: a detent
   * added DIAL_STEP (4) to that value, and the offset was derived as
   * `round(value/100 * maxOffset)`. With 32 agents (max offset 12) one detent
   * worked out to 0.48 columns, which rounds to no movement at all — so the
   * operator had to click twice for every column. The 0-100 value is a rotary
   * artifact of the on-screen knob; a physical encoder reports detents, so step
   * the offset directly and back-compute the knob value for display.
   */
  const turn = (input: Extract<DeckInput, { type: "encoder-turn" }>): void => {
    const grid = options.grid();
    const steps = input.ticks;
    if (steps === 0) return;
    const clamp = (value: number, max: number): number => Math.max(0, Math.min(max, value));

    if (input.index === 0 && state.mode === "logs") {
      const next = clamp(state.chatOffset + steps, chatMaxOffset);
      setLogsOffsets(state.eventOffset, next);
    } else if (input.index === 3 && state.mode === "logs") {
      const next = clamp(state.eventOffset + steps, eventMaxOffset);
      setLogsOffsets(next, state.chatOffset, false);
    } else if (input.index === 3) {
      const next = clamp(state.columnOffset + steps, maxColumnOffset(grid.total));
      setGridOffset(next);
    } else if (input.index === PROVIDER_SCROLL_ENCODER && state.mode === "grid") {
      // Grid only: the provider panel is part of the grid strip, so scrolling
      // it from cmd or logs would move something the operator cannot see.
      //
      // The stored offset is clamped *before* the step, not just after. The
      // panel clamps independently when it paints, so a provider leaving the
      // daemon's map — which the demo chord on this very knob does — leaves the
      // stored offset above the window actually on screen. Stepping from the
      // stale value then lands back on the row already showing, and the first
      // click after a fleet change does nothing at all.
      const max = maxProviderOffset(options.providerCount?.() ?? 0);
      publish({ ...state, providerOffset: clamp(clamp(state.providerOffset, max) + steps, max) });
    }
  };

  const pressDial = (index: number): void => {
    if (index === 0) return back();
    if (index !== 3) return;
    if (state.mode === "logs") {
      const next = cycleEventPage(state.eventOffset, eventMaxOffset + 8);
      return setLogsOffsets(next.eventOffset, state.chatOffset, false);
    }
    if (state.mode === "cmd") {
      return enterLogs();
    }
    const next = cycleWindow(state.columnOffset, options.grid().total);
    setGridOffset(next.columnOffset);
  };

  const handleReport = (report: Uint8Array): void => {
    const decoded = decodeInputReport(report);
    for (const input of decoded) if (input.type === "encoder-turn") turn(input);
    for (const input of decoded) {
      if (input.type === "key" && !input.pressed && input.index === 3 && state.mode === "cmd") releaseMic();
    }
    const edges = risingEdges(decoded, pressed);
    pressed = new Set(edges.pressed);

    // Checked against the report's own encoder state, not the rising edges: the
    // two knobs rarely go down in the same report, so an edge-only check would
    // almost never see both at once.
    const chordHeld =
      options.toggleDemo !== undefined &&
      DEMO_CHORD.every((index) =>
        decoded.some((input) => input.type === "encoder-button" && input.index === index && input.pressed),
      );
    if (chordHeld) {
      // Latch, or holding the pair would toggle once per poll.
      if (!chordActive) {
        chordActive = true;
        if (state.mode !== "grid") publish({ ...state, mode: "grid", focusedIdentifier: null, micHeld: false });
        options.toggleDemo?.();
      }
      return;
    }
    chordActive = false;

    for (const input of edges.events) {
      if (input.type === "key") pressKey(input.index);
      else if (input.type === "encoder-button") pressDial(input.index);
    }
  };

  return {
    state: (): ControllerState => state,
    handleReport,
    setLogs: (logs: StreamDeckLogs): void => {
      // Deliberately not falling back to `event_keys_visible`: that is the
      // server's own eight-key slice, already offset and padded with empty
      // slots. Paging a pre-sliced list adds the client's offset a second time,
      // so a press addressed the wrong event, and each padding slot normalised
      // into a pressable key that jumped nowhere.
      eventHistory = (logs.event_keys ?? []).map(toEventKey);
      const transcript = logs.transcript ?? [];
      transcriptHistory = transcript.map(toTranscriptRow);
      eventStarts = transcript.reduce<number[]>((starts, entry, index) => {
        if (entry.kind === "event_header") starts.push(index);
        return starts;
      }, []);
      eventMaxOffset = typeof logs.events_max_offset === "number" ? logs.events_max_offset : Math.max(0, eventHistory.length - 8);
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
      chatMaxOffset = Math.max(0, transcriptHistory.length - 1);
      // A live logs push is a refresh, not a navigation command. Preserve the
      // operator's two independent positions while the logs surface is open;
      // the server offsets are only the initial position when entering logs.
      const eventOffset = state.mode === "logs" ? state.eventOffset : logs.events_offset ?? 0;
      // Entering logs opens on the newest entry, which is offset 0: the daemon
      // flattens newest event first. Defaulting to the end of the list is the
      // mock's convention, where the flat list runs oldest-first, and it opened
      // the surface on the agent's oldest event instead of what it just said.
      const transcriptOffset = state.mode === "logs" ? state.chatOffset : logs.transcript_offset ?? 0;
      setLogsOffsets(eventOffset, transcriptOffset);
    },
    cancel: (): void => {
      pressed = new Set();
      if (state.micHeld) publish({ ...state, micHeld: false });
    },
  };
};

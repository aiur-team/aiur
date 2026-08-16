import { cycleEventPage, cycleWindow, EVENTS_PER_PAGE, maxColumnOffset } from "./dial.js";
import { decodeInputReport, risingEdges, type DeckInput } from "./input.js";
import { chatKind, rowKindOfRole, type DiffLine, type StreamDeckChannel, type StreamDeckGrid, type StreamDeckLogs, type TranscriptRow } from "./channel.js";
import { agentIndexForKey } from "./keys.js";
import { CHAT_WINDOW_ROWS, ensureEventVisible, selectedKeyAtOffset } from "./touchStrip/chatLog.js";
import { createTypewriter } from "./touchStrip/typewriter.js";
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
  /** `live` is the feed's sentinel *last* row — the right-hand end of the chat. */
  readonly kind: "live" | "event";
  /** Direction badge: EMIT, CONSUME, INFO, AGENT or SYSTEM. */
  readonly badge: string;
  readonly text: string;
  /** Relative timestamp such as "3m"; empty when the feed omits one. */
  readonly time: string;
  /**
   * Offset of this key's header in the flattened transcript — where pressing it
   * scrolls to. Carried per key rather than derived from a parallel array of
   * header positions: the client no longer has to reproduce the server's
   * anchoring rules to address a key, so the two cannot disagree about which
   * row a key means.
   */
  readonly start: number;
}

const asString = (value: unknown, fallback = ""): string => (typeof value === "string" ? value : fallback);
const asNumber = (value: unknown): number => (typeof value === "number" && Number.isFinite(value) ? value : 0);
/** Empty strings are absent values here: the daemon omits, rather than blanks, a missing diff line. */
const asText = (value: unknown): string | null => (typeof value === "string" && value !== "" ? value : null);

/** Normalises one server transcript row into a {@link TranscriptRow}. */
/**
 * Anything that is not a unified-diff marker is context. Passing an arbitrary
 * string through as a sign would let the feed pick the row's colour, and the
 * added/removed tint is the one thing a diff row's colour has to mean.
 */
const toDiffSign = (value: unknown): DiffLine["sign"] => {
  const sign = asString(value, " ");
  return sign === "+" || sign === "-" ? sign : " ";
};

const toTranscriptRow = (entry: Readonly<Record<string, unknown>>): TranscriptRow => {
  if (entry.kind === "diff_line") {
    return { kind: "diff_line", sign: toDiffSign(entry.sign), text: asString(entry.text) };
  }
  if (entry.kind === "event_header") {
    return {
      kind: "event_header",
      badge: asString(entry.badge, "INFO"),
      body: asString(entry.body),
      label: asString(entry.label, asString(entry.body)),
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
  return {
    kind: "message",
    role: asString(entry.role, "system"),
    body: asString(entry.body, asString(entry.line)),
    tool: asText(entry.tool),
    // The server's `row_kind`/`glyph` are authoritative (the emulator and the
    // device agree); a row that carried neither derives its class from its
    // role so a live push or legacy DTO still paints coherently.
    rowKind: entry.row_kind === undefined ? rowKindOfRole(asString(entry.role, "system")) : chatKind(entry.row_kind),
    glyph: asText(entry.glyph),
  };
};

/** Normalises one server event-key payload into an {@link EventKey}. */
const toEventKey = (event: Readonly<Record<string, unknown>>): EventKey => ({
  kind: event.kind === "live" ? "live" : "event",
  badge: event.kind === "live" ? "AGENT" : asString(event.badge, "INFO"),
  text: asString(event.text, asString(event.label, event.kind === "live" ? "LIVE" : "EVENT")),
  time: asString(event.time),
  start: asNumber(event.start),
});

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
    typewriter.observe(transcriptHistory, state.mode === "logs" && boundedChat >= maxChat);
    publish({
      ...state,
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
    publish({ ...state, mode: "logs", micHeld: false });
    setLogsOffsets(eventMaxOffset, chatMaxOffset);
  };

  const back = (): void => {
    if (state.mode === "logs") publish({ ...state, mode: "cmd", transcriptRows: [], micHeld: false });
    else if (state.mode === "cmd") publish({ ...state, mode: "grid", focusedIdentifier: null, micHeld: false });
  };

  const pressKey = (index: number): void => {
    const grid = options.grid();
    if (state.mode === "logs") {
      // Pressing a key scrolls the transcript to that key's own start. LIVE is
      // pinned to the bottom-right key and is not part of the scroll window, so
      // it is not addressable as eventOffset + index: key EVENTS_PER_PAGE (7)
      // is LIVE, the feed's last key, and keys 0-6 are the event page. Its
      // start is the newest row, so the same line of code serves both, and the
      // selection that follows is derived from where the scroll landed — which
      // is what makes exactly one of {LIVE, an event} active at a time.
      const position = index === EVENTS_PER_PAGE ? eventHistory.length - 1 : state.eventOffset + index;
      // An event slot that is not a real event is a padded empty key: the last
      // real event sits at `eventHistory.length - 2` (LIVE owns the last
      // index), so anything at or past LIVE's index on an event key is empty.
      if (index !== EVENTS_PER_PAGE && position >= eventHistory.length - 1) return;
      const entry = eventHistory[position];
      if (entry === undefined) return;
      setLogsOffsets(state.eventOffset, entry.start, true, position);
      return;
    }
    if (state.mode === "grid") {
      const identifier = identifierOf(agentAt(grid, state.columnOffset, index));
      if (identifier !== null) {
        // Switching to a *different* agent invalidates every logs position:
        // offsets and the typing reveal are indices into that agent's
        // transcript, and carrying them over would open the new agent's log at
        // an offset computed from the old one's. The first focus of a session
        // is not a switch — the daemon commonly pushes logs before the operator
        // presses anything, and discarding that payload would blank the surface
        // until the next flush.
        if (state.focusedIdentifier !== null && identifier !== state.focusedIdentifier) forgetLogs();
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
      // `eventMaxOffset + EVENTS_PER_PAGE + 1` is the total key count (events
      // plus the pinned LIVE key), which is what the dial's max-offset math
      // expects as its `eventCount`.
      const next = cycleEventPage(state.eventOffset, eventMaxOffset + EVENTS_PER_PAGE + 1);
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
      const previousSelection = state.selectedEvent;
      const previousChat = state.chatOffset;
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
      const following = !logsSeen || state.mode !== "logs" || previousChat >= previousMax;
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
      setLogsOffsets(state.eventOffset, rebased, false, previousSelection ?? undefined);
    },
    /**
     * Advances the live-typing reveal by one frame.
     *
     * Returns true when the surface owes the device another repaint. The host
     * owns the timer: the controller has no clock, which is what keeps every
     * transition in this module testable without waiting on one.
     */
    tickTyping: (): boolean => {
      if (state.mode !== "logs" || !typewriter.animating()) return false;
      const more = typewriter.tick();
      // `follow: false` — a frame of the reveal changes rendered text, nothing
      // positional. Letting it re-run the chase dragged the event-key window
      // back onto the selection every 40ms, so dial D was inert for the whole
      // time the agent appeared to be typing.
      setLogsOffsets(state.eventOffset, state.chatOffset, false, state.selectedEvent ?? undefined);
      return more;
    },
    cancel: (): void => {
      pressed = new Set();
      if (state.micHeld) publish({ ...state, micHeld: false });
    },
  };
};

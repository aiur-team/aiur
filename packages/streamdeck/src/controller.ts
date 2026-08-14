import { applyStep, columnOffsetFromDial, cycleEventPage, cycleWindow, dial3ValueFromEventOffset, maxColumnOffset } from "./dial.js";
import { decodeInputReport, risingEdges, type DeckInput } from "./input.js";
import type { StreamDeckChannel, StreamDeckGrid, StreamDeckLogs } from "./channel.js";
import { agentIndexForKey } from "./keys.js";

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
  readonly eventOffset: number;
  readonly chatOffset: number;
  readonly transcriptLines: readonly string[];
  readonly eventLines: readonly EventKey[];
  readonly eventHasPrevious: boolean;
  readonly eventHasNext: boolean;
  readonly chatHasPrevious: boolean;
  readonly chatHasNext: boolean;
  readonly micHeld: boolean;
}

export interface PhysicalControllerOptions {
  grid(): StreamDeckGrid;
  channel(): Pick<StreamDeckChannel, "focus" | "control"> | null;
  stateChanged(state: ControllerState): void;
}

const initialState: ControllerState = {
  mode: "grid",
  focusedIdentifier: null,
  columnOffset: 0,
  eventOffset: 0,
  chatOffset: 0,
  transcriptLines: [],
  eventLines: [],
  eventHasPrevious: false,
  eventHasNext: false,
  chatHasPrevious: false,
  chatHasNext: false,
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
  let dial3Value = 0;
  let chatDialValue = 0;
  let transcriptHistory: readonly string[] = [];
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

  const setLogsOffsets = (eventOffset: number, chatOffset: number): void => {
    const maxChat = chatMaxOffset;
    const boundedEvent = Math.max(0, Math.min(eventOffset, eventMaxOffset));
    const boundedChat = Math.max(0, Math.min(chatOffset, maxChat));
    if (state.mode !== "logs") {
      chatDialValue = maxChat === 0 ? 0 : (boundedChat / maxChat) * 100;
    }
    publish({
      ...state,
      eventOffset: boundedEvent,
      chatOffset: boundedChat,
      eventLines: eventHistory,
      transcriptLines: transcriptHistory.slice(boundedChat, boundedChat + 2),
      eventHasPrevious: boundedEvent > 0,
      eventHasNext: boundedEvent < eventMaxOffset,
      chatHasPrevious: boundedChat > 0,
      chatHasNext: boundedChat < maxChat,
    });
  };

  const back = (): void => {
    if (state.mode === "logs") publish({ ...state, mode: "cmd", transcriptLines: [], micHeld: false });
    else if (state.mode === "cmd") publish({ ...state, mode: "grid", focusedIdentifier: null, micHeld: false });
  };

  const pressKey = (index: number): void => {
    const grid = options.grid();
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
        publish({ ...state, mode: "logs", micHeld: false });
      } else if (index === 3) {
        publish({ ...state, micHeld: true });
      }
    }
  };

  const releaseMic = (): void => {
    if (state.micHeld) publish({ ...state, micHeld: false });
  };

  const turn = (input: Extract<DeckInput, { type: "encoder-turn" }>): void => {
    const grid = options.grid();
    if (input.index === 0 && state.mode === "logs") {
      const next = applyStep(chatDialValue, input.ticks > 0 ? 1 : -1);
      setLogsOffsets(state.eventOffset, Math.round((next / 100) * chatMaxOffset));
    } else if (input.index === 3 && state.mode === "logs") {
      const next = applyStep(dial3Value, input.ticks > 0 ? 1 : -1);
      setLogsOffsets(Math.round((next / 100) * eventMaxOffset), state.chatOffset);
      dial3Value = next;
    } else if (input.index === 3) {
      const next = applyStep(dial3Value, input.ticks > 0 ? 1 : -1);
      setGridOffset(columnOffsetFromDial(next, grid.total));
      dial3Value = next;
    }
  };

  const pressDial = (index: number): void => {
    if (index === 0) return back();
    if (index !== 3) return;
    if (state.mode === "logs") {
      const next = cycleEventPage(state.eventOffset, eventMaxOffset + 8);
      dial3Value = next.dial3Value;
      return setLogsOffsets(next.eventOffset, state.chatOffset);
    }
    if (state.mode === "cmd") {
      return publish({ ...state, mode: "logs", micHeld: false });
    }
    const next = cycleWindow(state.columnOffset, options.grid().total);
    dial3Value = next.dial3Value;
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
    for (const input of edges.events) {
      if (input.type === "key") pressKey(input.index);
      else if (input.type === "encoder-button") pressDial(input.index);
    }
  };

  return {
    state: (): ControllerState => state,
    handleReport,
    setTranscript: (lines: readonly string[]): void => {
      chatMaxOffset = Math.max(0, lines.length - 2);
      const offset = Math.min(state.chatOffset, chatMaxOffset);
      transcriptHistory = [...lines];
      setLogsOffsets(state.eventOffset, offset);
    },
    setLogs: (logs: StreamDeckLogs): void => {
      eventHistory = (logs.event_keys ?? logs.event_keys_visible ?? []).map(toEventKey);
      transcriptHistory = (logs.transcript ?? []).map((entry) => typeof entry.line === "string" ? entry.line : typeof entry.body === "string" ? entry.body : "[INFO]");
      eventMaxOffset = typeof logs.events_max_offset === "number" ? logs.events_max_offset : Math.max(0, eventHistory.length - 8);
      chatMaxOffset = typeof logs.transcript_max_offset === "number" ? logs.transcript_max_offset : Math.max(0, transcriptHistory.length - 2);
      // A live logs push is a refresh, not a navigation command. Preserve the
      // operator's two independent positions while the logs surface is open;
      // the server offsets are only the initial position when entering logs.
      const eventOffset = state.mode === "logs" ? state.eventOffset : logs.events_offset ?? 0;
      const transcriptOffset = state.mode === "logs" ? state.chatOffset : logs.transcript_offset ?? Math.max(0, transcriptHistory.length - 2);
      setLogsOffsets(eventOffset, transcriptOffset);
      if (state.mode !== "logs") {
        dial3Value = eventMaxOffset === 0 ? 0 : dial3ValueFromEventOffset(eventOffset, eventMaxOffset + 8);
      }
    },
    cancel: (): void => {
      pressed = new Set();
      if (state.micHeld) publish({ ...state, micHeld: false });
    },
  };
};

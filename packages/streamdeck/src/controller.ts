import { applyStep, columnOffsetFromDial, cycleEventPage, cycleWindow, maxColumnOffset } from "./dial.js";
import { decodeInputReport, risingEdges, type DeckInput } from "./input.js";
import type { StreamDeckChannel, StreamDeckGrid, StreamDeckLogs } from "./channel.js";

export type ControllerMode = "grid" | "cmd" | "logs";

export interface ControllerState {
  readonly mode: ControllerMode;
  readonly focusedIdentifier: string | null;
  readonly columnOffset: number;
  readonly eventOffset: number;
  readonly chatOffset: number;
  readonly transcriptLines: readonly string[];
  readonly eventLines: readonly string[];
  readonly eventHasPrevious: boolean;
  readonly eventHasNext: boolean;
  readonly chatHasPrevious: boolean;
  readonly chatHasNext: boolean;
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
};

const agentAt = (grid: StreamDeckGrid, offset: number, key: number): Readonly<Record<string, unknown>> | undefined =>
  grid.agents[(offset * 2) + (key % 8)];

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
  let eventHistory: readonly string[] = [];
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
    dial3Value = grid.total === 0 ? 0 : (offset / Math.max(1, maxColumnOffset(grid.total))) * 100;
    publish({ ...state, columnOffset: offset });
  };

  const setLogsOffsets = (eventOffset: number, chatOffset: number): void => {
    const maxChat = chatMaxOffset;
    const boundedEvent = Math.max(0, Math.min(eventOffset, eventMaxOffset));
    const boundedChat = Math.max(0, Math.min(chatOffset, maxChat));
    chatDialValue = maxChat === 0 ? 0 : (boundedChat / maxChat) * 100;
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
    if (state.mode === "logs") publish({ ...state, mode: "cmd", transcriptLines: [] });
    else if (state.mode === "cmd") publish({ ...state, mode: "grid", focusedIdentifier: null });
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
        const bucket = agent.bucket === "running" ? "pause" : agent.bucket === "paused" ? "resume" : null;
        if (bucket !== null) options.channel()?.control(identifier, bucket);
      } else if (index === 2) {
        publish({ ...state, mode: "logs", transcriptLines: transcriptHistory.slice(-2), chatOffset: Math.max(0, transcriptHistory.length - 2) });
      }
    }
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
    const next = cycleWindow(state.columnOffset, options.grid().total);
    dial3Value = next.dial3Value;
    setGridOffset(next.columnOffset);
  };

  const handleReport = (report: Uint8Array): void => {
    const decoded = decodeInputReport(report);
    for (const input of decoded) if (input.type === "encoder-turn") turn(input);
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
      eventHistory = (logs.event_keys ?? logs.event_keys_visible ?? []).map((event) => typeof event.label === "string" ? event.label : typeof event.text === "string" ? event.text : "EVENT");
      transcriptHistory = (logs.transcript ?? []).map((entry) => typeof entry.line === "string" ? entry.line : typeof entry.body === "string" ? entry.body : "[INFO]");
      eventMaxOffset = typeof logs.events_max_offset === "number" ? logs.events_max_offset : Math.max(0, eventHistory.length - 8);
      chatMaxOffset = typeof logs.transcript_max_offset === "number" ? logs.transcript_max_offset : Math.max(0, transcriptHistory.length - 2);
      setLogsOffsets(logs.events_offset ?? 0, logs.transcript_offset ?? Math.max(0, transcriptHistory.length - 2));
    },
  };
};

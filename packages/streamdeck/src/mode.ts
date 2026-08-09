/**
 * Pure state and commands shared by the Stream Deck renderers.
 *
 * This module deliberately does not talk to a Stream Deck, the DOM, a timer
 * API, or the network. Renderers apply `clear-live-refresh` effects through
 * their own timer adapter.
 */

export type StreamDeckMode = "grid" | "cmd" | "logs";
export type AgentId = string;
export type LiveRefreshTimer = unknown;

/** The agent-list projection consumed by grid and command renderers. */
export interface StreamDeckAgent {
  id: AgentId;
  paused: boolean;
  prioritized: boolean;
}

/**
 * The mode state's boundary with the dial ticket. Dial semantics own these
 * values' calculation; this state machine resets them when logs opens.
 */
export interface ModeDialState {
  dial0Rotation: number;
  dial3Rotation: number;
}

/**
 * The event-flattening ticket supplies this projection. The mode machine does
 * not inspect events; it only needs the newest valid chat index when logs
 * opens.
 */
export interface StreamDeckEventProjection {
  newestChatIndex: number;
}

export interface StreamDeckModeState extends ModeDialState {
  mode: StreamDeckMode;
  activeAgentId: AgentId | null;
  eventIndex: number;
  eventSelection: number;
  chatIndex: number;
  liveRefreshTimer: LiveRefreshTimer | null;
  micHeld: boolean;
}

export type CommandId = "pause" | "priority" | "logs" | "mic";

export interface CommandKey {
  command: CommandId;
  label: string;
}

export type ModeEffect =
  | {
      type: "clear-live-refresh";
      timer: LiveRefreshTimer;
    };

export type ModeAction =
  | { type: "agent.press"; agentId: AgentId }
  | { type: "command.press"; command: CommandId; bounds?: StreamDeckEventProjection }
  | { type: "back" }
  | { type: "mic.down" }
  | { type: "mic.up" }
  | { type: "mic.leave" }
  | { type: "mic.cancel" }
  | { type: "live-refresh.started"; timer: LiveRefreshTimer };

export interface ModeTransition {
  state: StreamDeckModeState;
  effects: readonly ModeEffect[];
}

export const createModeState = (): StreamDeckModeState => ({
  mode: "grid",
  activeAgentId: null,
  eventIndex: 0,
  eventSelection: 0,
  chatIndex: 0,
  dial0Rotation: 0,
  dial3Rotation: 0,
  liveRefreshTimer: null,
  micHeld: false,
});

/** Returns the eight command-mode keys; the final four are intentionally empty. */
export const commandKeys = (agent: Pick<StreamDeckAgent, "paused" | "prioritized">): readonly (CommandKey | null)[] => [
  { command: "pause", label: agent.paused ? "Play" : "Pause" },
  { command: "priority", label: agent.prioritized ? "Deprioritize" : "Prioritize" },
  { command: "logs", label: "Logs" },
  { command: "mic", label: "Mic" },
  null,
  null,
  null,
  null,
];

/**
 * Applies only state transitions owned by the mode machine. Pause and
 * priority mutations are renderer/provider concerns; their command labels are
 * derived by `commandKeys` from the latest agent projection.
 */
export const transitionMode = (state: StreamDeckModeState, action: ModeAction): ModeTransition => {
  if (action.type === "agent.press" && state.mode === "grid") {
    return { state: { ...state, mode: "cmd", activeAgentId: action.agentId }, effects: [] };
  }

  if (action.type === "command.press" && action.command === "logs" && state.mode === "cmd") {
    return {
      state: {
        ...state,
        mode: "logs",
        eventIndex: 0,
        eventSelection: 0,
        chatIndex: newestChatIndex(action.bounds),
        dial0Rotation: 0,
        dial3Rotation: 0,
        micHeld: false,
      },
      effects: [],
    };
  }

  if (action.type === "back" && state.mode === "logs") {
    const effects = state.liveRefreshTimer === null ? [] : [{ type: "clear-live-refresh" as const, timer: state.liveRefreshTimer }];

    return { state: { ...state, mode: "cmd", liveRefreshTimer: null, micHeld: false }, effects };
  }

  if (action.type === "back" && state.mode === "cmd") {
    return { state: { ...state, mode: "grid", activeAgentId: null, micHeld: false }, effects: [] };
  }

  if (action.type === "mic.down" && state.mode === "cmd") {
    return { state: { ...state, micHeld: true }, effects: [] };
  }

  if (isMicRelease(action) && state.mode === "cmd") {
    return { state: { ...state, micHeld: false }, effects: [] };
  }

  if (action.type === "live-refresh.started" && state.mode === "logs") {
    return { state: { ...state, liveRefreshTimer: action.timer }, effects: [] };
  }

  return { state, effects: [] };
};

const newestChatIndex = (bounds: StreamDeckEventProjection | undefined): number => Math.max(0, bounds?.newestChatIndex ?? 0);

const isMicRelease = (action: ModeAction): action is Extract<ModeAction, { type: "mic.up" | "mic.leave" | "mic.cancel" }> =>
  action.type === "mic.up" || action.type === "mic.leave" || action.type === "mic.cancel";

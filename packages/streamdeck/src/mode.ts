/**
 * Pure state and commands shared by the Stream Deck renderers.
 *
 * This module deliberately does not talk to a Stream Deck, the DOM, a timer
 * API, or the network. Renderers apply `clear-live-refresh` effects through
 * their own timer adapter.
 */

export type StreamDeckMode = "grid" | "cmd" | "logs" | "settings";
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

/**
 * The command-mode keys, in key order.
 *
 * `prioritize`/`deprioritize` are gone: the orchestrator ranks tickets itself
 * and the key was a second, weaker way to say the same thing. `settings` took
 * its slot, and `send`/`cancel` appear only once there is transcribed text to
 * act on.
 */
export type CommandId = "pause" | "logs" | "mic" | "settings" | "send" | "cancel";

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

/**
 * Returns the eight command-mode keys.
 *
 * This table is under a parity contract with the Elixir emulator's own command
 * row (`Aiur.StreamdeckLive`): the two surfaces must put the same command on the
 * same physical key, or muscle memory learned on one presses the wrong thing on
 * the other.
 *
 * `send` and `cancel` are present only while the voice buffer holds settled
 * text. They are not disabled-looking keys: there is nothing to send before the
 * operator has spoken, and a permanently lit Send would invite a press that
 * delivers an empty message.
 */
export const commandKeys = (
  agent: Pick<StreamDeckAgent, "paused">,
  hasTranscript = false,
): readonly (CommandKey | null)[] => [
  { command: "pause", label: agent.paused ? "Play" : "Pause" },
  { command: "logs", label: "Logs" },
  { command: "mic", label: "Mic" },
  { command: "settings", label: "Settings" },
  hasTranscript ? { command: "send", label: "Send" } : null,
  hasTranscript ? { command: "cancel", label: "Cancel" } : null,
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

  if (action.type === "command.press" && action.command === "settings" && state.mode === "cmd") {
    return { state: { ...state, mode: "settings", micHeld: false }, effects: [] };
  }

  // Settings is a leaf of cmd, not of grid: the operator arrived from a focused
  // agent and going back must return to that agent's commands, not drop the
  // focus they were in the middle of using.
  if (action.type === "back" && state.mode === "settings") {
    return { state: { ...state, mode: "cmd", micHeld: false }, effects: [] };
  }

  if (action.type === "back" && state.mode === "cmd") {
    return { state: { ...state, mode: "grid", activeAgentId: null, micHeld: false }, effects: [] };
  }

  // Both surfaces hold a microphone: `mic` in cmd and `TestMic` in settings.
  // They are the same press-and-hold gesture against the same capture, so they
  // are the same transition rather than two that can drift apart.
  if (action.type === "mic.down" && holdsMic(state.mode)) {
    return { state: { ...state, micHeld: true }, effects: [] };
  }

  if (isMicRelease(action) && holdsMic(state.mode)) {
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

/** The two modes with a hold-to-talk key on them. */
const holdsMic = (mode: StreamDeckMode): boolean => mode === "cmd" || mode === "settings";

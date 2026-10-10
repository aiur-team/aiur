import { cycleEventPage, cycleWindow, EVENTS_PER_PAGE, maxColumnOffset } from "./dial.js";
import { decodeInputReport, risingEdges, type DeckInput } from "./input.js";
import {
  clampHistoryOffset,
  clampOptionOffset,
  hasMoreHistory,
  HISTORY_PER_PAGE,
  isAnswerable,
} from "./commands.js";
import { maxProviderOffset, PROVIDER_SCROLL_ENCODER } from "./touchStrip/providerPanel.js";
import { agentLess } from "./surface.js";
import {
  CMD_PAUSE,
  CMD_LOGS,
  CMD_MIC,
  CMD_SETTINGS,
  CMD_COMMANDS,
  CMD_SEND,
  CMD_CANCEL,
  CMD_IMPLEMENT,
  SETTINGS_TEST_MIC,
  COMMANDS_MIC,
  type ControllerState,
  type PhysicalControllerOptions,
  DEMO_CHORD,
  initialState,
  agentAt,
  identifierOf,
  type ControllerCore,
} from "./controller/state.js";

import { createCommands } from "./controller/commands.js";
import { createGridLogs } from "./controller/grid-logs.js";
import { createVoiceSettings } from "./controller/voice-settings.js";

export type { ControllerMode, ControllerState, ControllerVoice, EventKey, PhysicalControllerOptions } from "./controller/state.js";
export { DEMO_CHORD } from "./controller/state.js";

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

  const publish = (next: ControllerState): void => {
    if (JSON.stringify(next) === JSON.stringify(state)) return;
    state = next;
    options.stateChanged(state);
  };

  const focusedAgent = (): Readonly<Record<string, unknown>> | undefined =>
    options.grid().agents.find((agent) => String(agent.identifier) === state.focusedIdentifier);

  const core: ControllerCore = {
    // A getter, not a copy: `publish` replaces `state`, and every part must see it.
    get state() {
      return state;
    },
    options,
    publish,
  };
  const voicePart = createVoiceSettings(core);
  const { stopVoice, leaveVoice, enterSettings, transcriptPresent, commandDictationPresent, sendTranscript, cancelTranscript, pressSettingsKey, holdMic, releaseMic } = voicePart;
  const logs = createGridLogs(core, voicePart);
  const { forgetLogs, setGridOffset, setLogsOffsets, enterLogs } = logs;
  const commands = createCommands(core, voicePart);
  const { enterCommands, leaveCommandDetail, pressCommandsKey, approveCommand, pageOptions } = commands;

  const back = (): void => {
    if (state.mode === "logs") publish({ ...state, mode: "cmd", transcriptRows: [], micHeld: false });
    else if (state.mode === "settings") {
      // Leaving settings must stop TestMic. Without this a hold that ended by
      // pressing dial A rather than by lifting the key leaves `parec` running
      // with nothing on screen to say so.
      stopVoice();
      publish({ ...state, mode: "cmd", micHeld: false });
    } else if (state.mode === "commands") {
      if (state.commandsView === "detail") leaveCommandDetail();
      else {
        leaveVoice();
        publish({
          ...state,
          mode: "cmd",
          micHeld: false,
          commandsView: "history",
          selectedCommand: null,
          commandDictation: false,
        });
      }
    } else if (state.mode === "cmd") {
      // The buffer is addressed to the agent that is being left, so it goes
      // with the focus. Carrying it to the next agent would put words the
      // operator said about one ticket into a Send aimed at another.
      leaveVoice();
      publish({ ...state, mode: "grid", focusedIdentifier: null, micHeld: false, hasTranscript: false });
    }
  };

  const pressKey = (index: number): void => {
    const grid = options.grid();
    if (state.mode === "logs") {
      logs.pressLogsKey(index);
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
    if (state.mode === "settings") {
      pressSettingsKey(index);
      return;
    }
    if (state.mode === "commands") {
      pressCommandsKey(index);
      return;
    }
    if (state.mode === "cmd") {
      const agent = focusedAgent();
      const identifier = state.focusedIdentifier;
      if (identifier === null || agent === undefined) return;
      if (index === CMD_PAUSE && !agentLess(agent)) {
        // Anything not already paused can be paused. Restricting this to the
        // `running` bucket left the key inert for an alert or stuck agent —
        // exactly the states an operator most wants to halt.
        options.channel()?.control(identifier, agent.bucket === "paused" ? "resume" : "pause");
      } else if (index === CMD_LOGS) {
        enterLogs();
      } else if (index === CMD_MIC) {
        holdMic();
      } else if (index === CMD_SETTINGS) {
        enterSettings();
      } else if (index === CMD_COMMANDS) {
        enterCommands();
      } else if (index === CMD_SEND) {
        sendTranscript(identifier);
      } else if (index === CMD_CANCEL) {
        cancelTranscript();
      } else if (index === CMD_IMPLEMENT && agentLess(agent)) {
        // The deck asks; the daemon dispatches. `implement` applies the
        // configured lifecycle todo label through the same path as the CLI's
        // `--todo`, so the ticket enters the queue the orchestrator already
        // reads instead of being started behind its back.
        options.channel()?.control(identifier, "implement");
        publish({ ...state, implementQueued: true });
      }
    }
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
      const next = clamp(state.chatOffset + steps, logs.chatMaxOffset());
      setLogsOffsets(state.eventOffset, next);
    } else if (input.index === 3 && state.mode === "logs") {
      const next = clamp(state.eventOffset + steps, logs.eventMaxOffset());
      setLogsOffsets(next, state.chatOffset, false);
    } else if (input.index === 3 && state.mode === "commands") {
      // Dial D pages the Commands page: the history window on the history view,
      // the option window on the detail view.
      if (state.commandsView === "detail" && state.selectedCommand !== null) {
        const count = state.selectedCommand.options.length;
        const next = clampOptionOffset(state.optionOffset + steps, count);
        publish({ ...state, optionOffset: next, selectedOption: null });
      } else {
        const count = state.commandsPage.items.length;
        const next = clampHistoryOffset(state.historyOffset + steps, count);
        publish({ ...state, historyOffset: next, historySelection: null });
      }
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
      const next = cycleEventPage(state.eventOffset, logs.eventMaxOffset() + EVENTS_PER_PAGE + 1);
      return setLogsOffsets(next.eventOffset, state.chatOffset, false);
    }
    if (state.mode === "commands") {
      if (
        state.commandsView === "detail" &&
        state.selectedCommand !== null &&
        isAnswerable(state.selectedCommand.status) &&
        (state.selectedOption !== null || state.commandDictation)
      ) {
        // The knob becomes Approve: pressing it is the deliberate second action
        // that turns a read option or a dictated response into the answer. It
        // does nothing while nothing is armed, so it can never commit by
        // accident.
        // The key derivation is async (SHA-256), so the answer is sent after
        // the digest resolves; the deliberate second action has already
        // happened, so there is nothing else to block on here.
        void approveCommand(state.selectedCommand);
        return;
      }
      if (state.commandsView === "detail" && state.selectedCommand !== null) {
        return pageOptions();
      }
      // History view: cycle the page, wrapping, exactly as dial D cycles the
      // event window in logs.
      const count = state.commandsPage.items.length;
      const next = hasMoreHistory(state.historyOffset, count) ? state.historyOffset + HISTORY_PER_PAGE : 0;
      publish({ ...state, historyOffset: clampHistoryOffset(next, count), historySelection: null });
      return;
    }
    if (state.mode === "cmd") {
      return enterLogs();
    }
    // Settings pages with key 7, not with a knob: the grid window this would
    // otherwise cycle is not on screen, so the press would move something the
    // operator cannot see.
    if (state.mode === "settings") return;
    const next = cycleWindow(state.columnOffset, options.grid().total);
    setGridOffset(next.columnOffset);
  };

  const handleReport = (report: Uint8Array): void => {
    const decoded = decodeInputReport(report);
    for (const input of decoded) if (input.type === "encoder-turn") turn(input);
    // Key-up is handled before the rising-edge pass, and from the report's own
    // state rather than from an edge: a release must end the capture even when
    // it shares a report with another press. The hold keys are on different
    // surfaces, so each mode listens to exactly one index.
    for (const input of decoded) {
      if (input.type !== "key" || input.pressed) continue;
      if (state.mode === "cmd" && input.index === CMD_MIC) releaseMic();
      else if (state.mode === "settings" && input.index === SETTINGS_TEST_MIC) releaseMic();
      else if (state.mode === "commands" && input.index === COMMANDS_MIC) releaseMic();
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
        if (state.mode !== "grid") {
          // The chord swaps the data source under the surface, so it drops the
          // focus — and with the focus goes the buffer and any live capture.
          leaveVoice();
          publish({ ...state, mode: "grid", focusedIdentifier: null, micHeld: false, hasTranscript: false });
        }
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
    setLogs: logs.setLogs,
    tickTyping: logs.tickTyping,
    /**
     * Re-reads whether the voice buffer holds text.
     *
     * The controller has no way to observe a transcript landing — it arrives on
     * the channel, is applied by the voice session, and never passes through
     * here. The host calls this on a voice update so the Send and Cancel keys
     * appear as soon as there is something to send. `publish` diffs on value,
     * so a call that changes nothing costs nothing.
     */
    refreshVoice: (): void => {
      publish({ ...state, hasTranscript: transcriptPresent(), commandDictation: commandDictationPresent() });
    },
    cancel: (): void => {
      pressed = new Set();
      // The device went away mid-hold. Stop capture, or `parec` keeps recording
      // against a deck that is no longer there.
      stopVoice();
      if (state.micHeld) publish({ ...state, micHeld: false, hasTranscript: transcriptPresent(), commandDictation: commandDictationPresent() });
    },
    setCommands: commands.setCommands,
    commandAnswered: commands.commandAnswered,
    commandsError: commands.commandsError,
    /**
     * Applies a fresh grid: the fleet state the Implement key was waiting on.
     *
     * The controller pulls the grid rather than being pushed it, so it cannot
     * see a snapshot land on its own. The host calls this when one does, which
     * is what retires the `QUEUED` sub-label: from that point the key shows
     * whatever the ticket's real bucket now is.
     */
    gridChanged: (): void => {
      if (state.implementQueued) publish({ ...state, implementQueued: false });
    },
  };
};

/** The Commands page: history, one Command's detail, and the answer path. */
import { type StreamDeckCommand, type StreamDeckCommandAnswerResult, type StreamDeckCommandAnswerError, type StreamDeckCommandsPage } from "../channel.js";
import {
  clampOptionOffset,
  commandIdempotencyKey,
  hasMoreOptions,
  canAnswerOnDeck,
} from "../commands.js";
import {
  COMMANDS_OPTION_SLOTS,
  COMMANDS_MIC,
  COMMANDS_APPROVE,
  COMMANDS_CANCEL,
  COMMANDS_MORE,
  type ControllerState,
  type ControllerCore,
} from "./state.js";

import type { VoiceSettings } from "./voice-settings.js";

export const createCommands = (core: ControllerCore, { voice, leaveVoice, holdMic }: Pick<VoiceSettings, "voice" | "leaveVoice" | "holdMic">) => {
  const { options, publish } = core;
  const pending = new Map<string, { decisionId: string; key: number }>();
  let feedbackTimer: ReturnType<typeof setTimeout> | undefined;

  /**
   * Opens the Commands page for the focused agent, at its history.
   *
   * The Commands key is always present on the agent row — it is a destination,
   * not an alert — so this never depends on whether a Command exists. A
   * leftover chat dictation from the agent row is cleared on entry: words said
   * about a ticket's conversation must not silently become a Command answer.
   */
  const enterCommands = (): void => {
    clearTimeout(feedbackTimer);
    pending.clear();
    leaveVoice();
    publish({
      ...core.state,
      mode: "commands",
      micHeld: false,
      commandsView: "history",
      historyOffset: 0,
      historySelection: null,
      selectedCommand: null,
      optionOffset: 0,
      selectedOption: null,
      commandDictation: false,
      commandsError: null,
      commandFeedback: null,
    });
  };

  /**
   * Enters the detail view for one Command.
   *
   * Dictation is addressed to exactly one Command: entering another Command
   * discards any text held for the previous one, so an answer can never be
   * sent to the wrong decision.
   */
  const enterCommandDetail = (command: StreamDeckCommand): void => {
    clearTimeout(feedbackTimer);
    pending.clear();
    leaveVoice();
    publish({
      ...core.state,
      commandsView: "detail",
      selectedCommand: command,
      historySelection: null,
      optionOffset: 0,
      selectedOption: null,
      commandDictation: false,
      commandsError: null,
      commandFeedback: null,
    });
  };

  /** Returns to the history view from a Command's detail. */
  const leaveCommandDetail = (): void => {
    clearTimeout(feedbackTimer);
    pending.clear();
    leaveVoice();
    publish({
      ...core.state,
      commandsView: "history",
      selectedCommand: null,
      selectedOption: null,
      optionOffset: 0,
      commandDictation: false,
      commandsError: null,
      commandFeedback: null,
    });
  };

  /**
   * One key press on the Commands page.
   *
   * On the history view, pressing a Command enters its detail (answering for an
   * open one, read-only for a completed one). On the detail view, an option key
   * selects for reading and never commits, the mic starts a dictation, and
   * Approve/Cancel settle a spoken custom response.
   */
  const pressCommandsKey = (index: number): void => {
    if (core.state.commandsView === "history") {
      const command = core.state.commandsPage.items[core.state.historyOffset + index];
      if (command === undefined) return;
      // Focus the key and show its detail; entering the detail is what happens
      // next, and read-only versus answerable is decided by the detail view.
      enterCommandDetail(command);
      return;
    }
    const command = core.state.selectedCommand;
    if (command === null || command.answerable_on_deck === false) return;
    if (index < COMMANDS_OPTION_SLOTS) {
      // Selecting an option is reading, not committing — the deliberate
      // second action (dial D) is what turns it into the answer.
      const optionIndex = core.state.optionOffset + index;
      if (optionIndex >= command.options.length) return;
      publish({ ...core.state, selectedOption: optionIndex, commandsError: null });
      return;
    }
    if (index === COMMANDS_MIC && canAnswerOnDeck(command)) {
      holdMic();
      return;
    }
    if (index === COMMANDS_APPROVE && core.state.commandDictation && canAnswerOnDeck(command)) {
      // Fire-and-forget: the key derivation is async (SHA-256), so the answer
      // is sent once the digest resolves.
      void approveCommand(command);
      return;
    }
    if (index === COMMANDS_CANCEL && core.state.commandDictation) {
      cancelCommandDictation();
      return;
    }
    if (index === COMMANDS_MORE) {
      pageOptions();
    }
  };

  /** Discards the Commands dictation buffer and hides Approve/Cancel. */
  const cancelCommandDictation = (): void => {
    voice()?.clear();
    publish({ ...core.state, commandDictation: false });
  };

  /**
   * Turns the reading into the answer and sends it to the Command.
   *
   * Approving is always the deliberate second action: the operator either read
   * an option (dial D) or dictated a custom response (dial D or the Approve
   * key). The custom response wins when both exist — it is the "none of the
   * above" path, and a spoken instruction must override a stale selection. The
   * idempotency key is derived from the Command and the answer content, so a
   * dropped reply that is retried records a replay, never a second decision.
   */
  const approveCommand = async (command: StreamDeckCommand): Promise<void> => {
    if (!canAnswerOnDeck(command)) return;
    const port = voice();
    const response = port?.hasMessage() === true ? port.message() : null;
    const answer =
      response !== null && response !== ""
        ? { custom_response: response }
        : core.state.selectedOption !== null
          ? { option_id: command.options[core.state.selectedOption]?.id ?? "" }
          : null;
    if (answer === null || answer.option_id === "") return;
    const target = { decisionId: command.decision_id, key: response ? COMMANDS_APPROVE : (core.state.selectedOption ?? 0) - core.state.optionOffset };
    const idempotencyKey = await commandIdempotencyKey(command.decision_id, answer);
    pending.set(idempotencyKey, target);
    options.channel()?.answerCommand(command.decision_id, command.version, idempotencyKey, answer);
    // The buffer is consumed by the answer; it must not also sit in the cmd
    // surface's Send buffer later.
    port?.clear();
    publish({ ...core.state, commandDictation: false, selectedOption: null, commandsError: null });
  };

  /** Pages the detail view's options forward, wrapping back to the first page. */
  const pageOptions = (): void => {
    if (core.state.selectedCommand === null) return;
    const count = core.state.selectedCommand.options.length;
    if (count <= COMMANDS_OPTION_SLOTS) return;
    const next = core.state.optionOffset + COMMANDS_OPTION_SLOTS;
    publish({ ...core.state, optionOffset: hasMoreOptions(core.state.optionOffset, count) ? clampOptionOffset(next, count) : 0, selectedOption: null });
  };

  /**
   * Applies a `commands` push: a fresh history page for the focused agent.
   *
   * A push can arrive while the operator is reading a detail view (a decision
   * elsewhere changed). The detail is re-read from the pushed page if the
   * Command is still in it, so the strip does not describe a Command that is
   * no longer current; a Command that left the page drops back to history.
   */
  const setCommands = (page: StreamDeckCommandsPage): void => {
    let next: ControllerState = { ...core.state, commandsPage: page, commandsError: core.state.commandFeedback ? core.state.commandsError : null };
    if (core.state.commandsView === "detail" && core.state.selectedCommand !== null) {
      const refreshed = page.items.find((item) => item.decision_id === core.state.selectedCommand?.decision_id);
      if (refreshed !== undefined) next = { ...next, selectedCommand: refreshed };
      else if (!core.state.commandFeedback) next = { ...next, commandsView: "history" };
    }
    publish(next);
  };

  /**
   * Applies an `answer_command` reply: the durable answer was recorded.
   *
   * The refreshed Command carries its new status (decided/acknowledged), so
   * the detail view becomes read-only: the strip shows what was decided and
   * no Approve affordance remains. The page is also updated in place so the
   * history list reflects the answer.
   */
  const commandAnswered = (result: StreamDeckCommandAnswerResult): void => {
    clearTimeout(feedbackTimer);
    const answered = result.decision;
    const page: StreamDeckCommandsPage = {
      ...core.state.commandsPage,
      items: core.state.commandsPage.items.map((item) => (item.decision_id === answered.decision_id ? answered : item)),
    };
    publish({
      ...core.state,
      commandsPage: page,
      selectedCommand: core.state.selectedCommand?.decision_id === answered.decision_id ? answered : core.state.selectedCommand,
      commandDictation: false,
      selectedOption: null,
      commandsError: null,
      commandFeedback: null,
    });
  };

  /**
   * Applies a channel error for the Commands page or an answer: the strip
   * shows the reason instead of silently doing nothing.
   */
  const commandsError = (reason: string, outcome?: StreamDeckCommandAnswerError, requestKey?: string): void => {
    const target = requestKey === undefined ? [...pending.values()].at(-1) : pending.get(requestKey);
    if (requestKey === undefined) pending.clear();
    else pending.delete(requestKey);
    if (outcome === undefined) {
      clearTimeout(feedbackTimer);
      publish({ ...core.state, commandFeedback: null, commandsError: reason });
      return;
    }
    const winner = outcome.reason === "already_answered" ? outcome.winner : null;
    const title = outcome.reason === "already_answered" ? winner?.summary || "Already answered"
      : outcome.reason === "withdrawn" ? "Command withdrawn" : "Command changed";
    const label = outcome.reason === "already_answered" ? `Answered by ${winner?.actor_kind ?? "someone else"}`
      : outcome.reason === "withdrawn" ? outcome.status : "Refresh and retry";
    if (target !== undefined && core.state.mode === "commands" && core.state.selectedCommand?.decision_id === target.decisionId) {
      clearTimeout(feedbackTimer);
      publish({ ...core.state, commandsError: `${label}: ${title}`, commandFeedback: { ...target, title, label } });
      feedbackTimer = setTimeout(() => {
        const stillListed = core.state.commandsPage.items.some((item) => item.decision_id === target.decisionId);
        publish({ ...core.state, commandsView: stillListed ? core.state.commandsView : "history", commandFeedback: null, commandsError: null });
      }, 3_000);
      feedbackTimer.unref?.();
    }
    if (core.state.focusedIdentifier !== null) options.channel()?.focus(core.state.focusedIdentifier);
  };

  return {
    enterCommands,
    leaveCommandDetail,
    pressCommandsKey,
    approveCommand,
    pageOptions,
    setCommands,
    commandAnswered,
    commandsError,
  };
};

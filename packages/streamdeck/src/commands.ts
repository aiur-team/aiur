/**
 * The Commands surface's pure view model: what the eight keys and the touch
 * strip paint, derived from the focused agent's Command history.
 *
 * The page is history-first, per the operator refinement: opening Commands
 * lands on the agent's past Commands (active ones highlighted), and selecting
 * an open one enters the answer flow — description in the bottom panel,
 * options on the key row, approve with a knob, or hold the mic for a spoken
 * custom response. Completed Commands are read-only: they show what was asked
 * and what was decided, with no Approve affordance.
 *
 * Nothing here talks to the deck, the channel, or a timer. It takes the
 * channel's allowlisted page and returns what to paint, so every decision is
 * testable without a device.
 */

import type { AgentInput } from "./keys.js";
import type { StreamDeckCommand, StreamDeckCommandsPage } from "./channel.js";

/** Command keys shown per history page. The whole key grid, like the logs event window. */
export const HISTORY_PER_PAGE = 8;
/** Option keys shown per detail page, leaving the mic, approve, cancel and paging slots. */
export const OPTIONS_PER_PAGE = 4;
/** Slot of the hold-to-talk mic key in the answerable detail view. */
export const COMMANDS_MIC_SLOT = 4;
/** Slot of the Approve key, present only while the dictation buffer holds text. */
export const COMMANDS_APPROVE_SLOT = 5;
/** Slot of the Cancel key, present only while the dictation buffer holds text. */
export const COMMANDS_CANCEL_SLOT = 6;
/** Slot of the options paging key, present only when options overflow one page. */
export const COMMANDS_MORE_SLOT = 7;

/** A Command is answerable only while it is open or deferred to the Executor. */
export const isAnswerable = (status: unknown): boolean => status === "open" || status === "deferred";

/** Whether a history entry is read-only (already answered, dismissed, ...). */
export const isAnswered = (status: unknown): boolean => !isAnswerable(status);

/** The greatest history offset that still shows a full window of items. */
export const maxHistoryOffset = (count: number): number => Math.max(0, count - HISTORY_PER_PAGE);

/** The greatest option offset that still shows a full window of options. */
export const maxOptionOffset = (count: number): number => Math.max(0, count - OPTIONS_PER_PAGE);

/** Clamps a requested offset into a valid history-window start. */
export const clampHistoryOffset = (offset: number, count: number): number =>
  Math.max(0, Math.min(offset, maxHistoryOffset(count)));

/** Clamps a requested offset into a valid option-window start. */
export const clampOptionOffset = (offset: number, count: number): number =>
  Math.max(0, Math.min(offset, maxOptionOffset(count)));

/** Whether more history exists below the window at `offset`. */
export const hasMoreHistory = (offset: number, count: number): boolean => offset + HISTORY_PER_PAGE < count;

/** Whether more options exist below the window at `offset`. */
export const hasMoreOptions = (offset: number, count: number): boolean => offset + OPTIONS_PER_PAGE < count;

/** Human page position ("2/3"), or "" for a single page. */
export const historyPageLabel = (offset: number, count: number): string => {
  const pages = Math.max(1, Math.ceil(count / HISTORY_PER_PAGE));
  return pages <= 1 ? "" : `${Math.floor(offset / HISTORY_PER_PAGE) + 1}/${pages}`;
};

/** Human option page position ("2/2"), or "" for a single page. */
export const optionPageLabel = (offset: number, count: number): string => {
  const pages = Math.max(1, Math.ceil(count / OPTIONS_PER_PAGE));
  return pages <= 1 ? "" : `${Math.floor(offset / OPTIONS_PER_PAGE) + 1}/${pages}`;
};

/** The operator-facing status badge for a Command, used on its key and the strip. */
export const commandStatusLabel = (status: unknown): string => {
  if (status === "open") return "OPEN";
  if (status === "deferred") return "DEFERRED";
  if (status === "decided" || status === "acknowledged" || status === "resolved") return "ANSWERED";
  if (status === "dismissed" || status === "expired") return "CLOSED";
  return typeof status === "string" ? status.toUpperCase() : "UNKNOWN";
};

/** The recorded outcome text of an answered Command, for read-only display. */
export const commandOutcomeLabel = (command: StreamDeckCommand): string | null => {
  const answer = command.answer;
  if (answer === null || answer === undefined) return null;
  if (typeof answer.custom_response === "string" && answer.custom_response !== "") {
    return `Spoken: ${answer.custom_response}`;
  }
  if (typeof answer.selected_option_id === "string" && answer.selected_option_id !== "") {
    const option = command.options.find((candidate) => candidate.id === answer.selected_option_id);
    return option === undefined ? "Option chosen" : `Chose: ${option.label}`;
  }
  return "Answered";
};

/**
 * One command history key.
 *
 * Active (answerable) commands use an amber OPEN badge, completed ones a muted
 * ANSWERED badge, and the selected key reuses the log surface's plate/rail/
 * inverted-chip selection idiom so a focused Command reads the same as a
 * focused event.
 */
const commandKey = (command: StreamDeckCommand, selected: boolean): AgentInput => {
  const answerable = isAnswerable(command.status);
  return {
    identifier: `command:${command.decision_id}`,
    title: command.question,
    vendor: "commands",
    icon: answerable ? "question" : "check",
    role: "event",
    subLabel: commandStatusLabel(command.status),
    timeLabel: "",
    selected,
    bucket: "queued",
    progress_percent: null,
    priority: false,
    dependency_ready: true,
  };
};

/**
 * The eight history keys, newest first.
 *
 * `offset` is the history-window start; item `offset + i` is painted on key
 * `i`, so the newest item is the leftmost key and paging slides the window to
 * the right — the same direction the logs event window pages. Command keys are
 * self-describing (question + status badge), so unlike the event window they
 * need no pinned LIVE key to mark currency.
 */
export function historyKeyDescriptors(
  page: StreamDeckCommandsPage,
  offset: number,
  selected: number | null,
): (AgentInput | undefined)[] {
  const count = page.items.length;
  const clamped = clampHistoryOffset(offset, count);
  return Array.from({ length: HISTORY_PER_PAGE }, (_, index) => {
    const item = page.items[clamped + index];
    if (item === undefined) return undefined;
    return commandKey(item, clamped + index === selected);
  });
}

/** One option key: the option label with the selected key using the event idiom. */
const optionKey = (command: StreamDeckCommand, option: { label: string }, optionIndex: number, selected: boolean): AgentInput => ({
  identifier: `option:${command.decision_id}:${optionIndex}`,
  title: option.label,
  vendor: "commands",
  icon: "option",
  role: "event",
  subLabel: `OPT ${optionIndex + 1}`,
  timeLabel: "",
  selected,
  bucket: "queued",
  progress_percent: null,
  priority: false,
  dependency_ready: true,
});

/**
 * The eight detail/answer keys.
 *
 * An answerable Command paints its options (paged), the always-present
 * hold-to-talk mic, Approve and Cancel while the dictation buffer holds text,
 * and a paging key when options overflow. A completed Command is read-only:
 * the options stay for reading and no mic, Approve or Cancel exists.
 */
export function detailKeyDescriptors(
  command: StreamDeckCommand,
  optionOffset: number,
  selectedOption: number | null,
  micHeld: boolean,
  hasDictation: boolean,
): (AgentInput | undefined)[] {
  const answerable = isAnswerable(command.status);
  const count = command.options.length;
  const clamped = clampOptionOffset(optionOffset, count);

  const slots: (AgentInput | undefined)[] = Array.from({ length: OPTIONS_PER_PAGE }, (_, index) => {
    const option = command.options[clamped + index];
    if (option === undefined) return undefined;
    return optionKey(command, option, clamped + index, clamped + index === selectedOption);
  });

  // The mic is the same hold-to-talk gesture as the cmd surface's Mic key.
  slots[COMMANDS_MIC_SLOT] = answerable
    ? {
        identifier: `command:${command.decision_id}:mic`,
        title: "Mic",
        vendor: "commands",
        icon: "mic",
        role: "command",
        subLabel: micHeld ? "LIVE" : "HOLD",
        timeLabel: "",
        selected: false,
        bucket: "queued",
        progress_percent: null,
        priority: false,
        dependency_ready: true,
      }
    : undefined;

  // Approve and Cancel are deliberate second actions that appear only once the
  // dictation buffer holds text — the same pattern as Send/Cancel on the cmd
  // surface. Approve is the green, unmistakably-committing key.
  if (answerable && hasDictation) {
    slots[COMMANDS_APPROVE_SLOT] = {
      identifier: `command:${command.decision_id}:approve`,
      title: "Approve",
      vendor: "commands",
      icon: "approve",
      role: "command",
      subLabel: "SEND",
      timeLabel: "",
      selected: false,
      bucket: "running",
      progress_percent: null,
      priority: false,
      dependency_ready: true,
    };
    slots[COMMANDS_CANCEL_SLOT] = {
      identifier: `command:${command.decision_id}:cancel`,
      title: "Cancel",
      vendor: "commands",
      icon: "cancel",
      role: "command",
      subLabel: "DISCARD",
      timeLabel: "",
      selected: false,
      bucket: "queued",
      progress_percent: null,
      priority: false,
      dependency_ready: true,
    };
  } else if (answerable && hasMoreOptions(optionOffset, count)) {
    slots[COMMANDS_MORE_SLOT] = {
      identifier: `command:${command.decision_id}:more`,
      title: "More",
      vendor: "commands",
      icon: "next",
      role: "command",
      subLabel: optionPageLabel(optionOffset, count),
      timeLabel: "",
      selected: false,
      bucket: "queued",
      progress_percent: null,
      priority: false,
      dependency_ready: true,
    };
  }

  return slots;
}

/**
 * The description the strip paints for the selected reading position.
 *
 * In the detail view this is the Command's own description, the selected
 * option's detail, or — for a completed Command — the recorded outcome.
 */
export function commandDescription(command: StreamDeckCommand, selectedOption: number | null): string {
  const contextShort = command.context?.short;
  if (selectedOption !== null) {
    const option = command.options[selectedOption];
    if (option !== undefined) {
      const detail = [option.description, option.benefits, option.drawbacks, option.risk]
        .filter((part): part is string => typeof part === "string" && part !== "")
        .join(" · ");
      if (detail !== "") return detail;
    }
  }
  if (typeof contextShort === "string" && contextShort !== "") return contextShort;
  return "No description";
}

/**
 * A stable idempotency key for one intended answer.
 *
 * The key is derived from the Command id and the answer content, so a retry
 * after a dropped reply reuses the same key and the server records a duplicate
 * (replay) rather than a second decision. It deliberately does not include a
 * timestamp or a counter: either would make every retry a brand-new decision.
 */
export function commandIdempotencyKey(
  decisionId: string,
  answer: { option_id?: string; custom_response?: string },
): string {
  const content = answer.option_id ?? answer.custom_response ?? "";
  let hash = 0;
  for (let i = 0; i < content.length; i += 1) {
    hash = (hash * 31 + content.charCodeAt(i)) | 0;
  }
  return `sd_${decisionId}_${(hash >>> 0).toString(36)}`;
}

/** The number of open/deferred Commands in a page — the "current" count. */
export function activeCommandCount(page: StreamDeckCommandsPage): number {
  return page.items.reduce((count, item) => (isAnswerable(item.status) ? count + 1 : count), 0);
}

/** The touch strip's view model for the Commands page. */
export interface CommandsPanelModel {
  readonly view: "history" | "detail";
  readonly ticketId: string;
  /** Answerable (open/deferred) Commands, from the currently-loaded page. */
  readonly activeCount: number;
  /** Total Commands across all pages, when the store reported one. */
  readonly total: number | null;
  /** Human page position ("2/3"), or "" for a single page. */
  readonly page: string;
  /** The Command's question (detail) or a history heading. */
  readonly title: string;
  /** The reading: Command description, selected option detail, or a hint. */
  readonly description: string;
  /** The status badge: OPEN, ANSWERED, ... */
  readonly status: string;
  readonly answerable: boolean;
  /** True when the Approve affordance is armed (a selected option or dictation). */
  readonly approving: boolean;
  /** The recorded outcome of a completed Command, or null when none. */
  readonly recorded: string | null;
  /** A channel error (a failed page load or answer), shown instead of the reading. */
  readonly error?: string | null;
}

/**
 * The strip model for the history view.
 *
 * The history strip is a heading, not a full reading: it names the agent, how
 * many Commands are awaiting an answer, and the page position. Selecting a key
 * is what enters the detail view where reading happens. An explicitly
 * unavailable page (the store could not be read) is stated as such — never
 * mistaken for "no open Commands".
 */
export function historyPanel(
  page: StreamDeckCommandsPage,
  offset: number,
  ticketId: string,
): CommandsPanelModel {
  if (page.unavailable === true) {
    return {
      view: "history",
      ticketId,
      activeCount: 0,
      total: null,
      page: "",
      title: "Commands",
      description: "Commands unavailable",
      status: "UNAVAILABLE",
      answerable: false,
      approving: false,
      recorded: null,
    };
  }
  const count = page.items.length;
  const active = activeCommandCount(page);
  const pageLabel = historyPageLabel(offset, count);
  return {
    view: "history",
    ticketId,
    activeCount: active,
    total: typeof page.total === "number" ? page.total : null,
    page: pageLabel,
    title: "Commands",
    description: active === 0 ? "No open Commands" : `${active} awaiting your answer`,
    status: active === 0 ? "CLEAR" : "OPEN",
    answerable: false,
    approving: false,
    recorded: null,
  };
}

/**
 * The strip model for the detail view: the Command question, the reading
 * (description or selected option), the approval state, and — for a completed
 * Command — what was decided.
 */
export function detailPanel(
  command: StreamDeckCommand,
  selectedOption: number | null,
  hasDictation: boolean,
): CommandsPanelModel {
  const answerable = isAnswerable(command.status);
  const recorded = answerable ? null : commandOutcomeLabel(command);
  return {
    view: "detail",
    ticketId: command.ticket?.identifier ?? "",
    activeCount: 0,
    total: null,
    page: "",
    title: command.question,
    description: commandDescription(command, selectedOption),
    status: commandStatusLabel(command.status),
    answerable,
    approving: answerable && (selectedOption !== null || hasDictation),
    recorded,
  };
}

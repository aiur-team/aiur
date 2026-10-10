/** Types, key slots and wire normalisers shared by the controller and its parts. */
import { chatKind, rowKindOfRole, type DiffLine, type StreamDeckChannel, type StreamDeckCommand, type StreamDeckCommandsPage, type StreamDeckGrid, type TranscriptRow } from "../channel.js";
import {
  COMMANDS_APPROVE_SLOT,
  COMMANDS_CANCEL_SLOT,
  COMMANDS_MIC_SLOT,
  COMMANDS_MORE_SLOT,
  OPTIONS_PER_PAGE,
} from "../commands.js";
import { agentIndexForKey } from "../keys.js";
import { SETTINGS_NEXT_PAGE_KEY, SETTINGS_TEST_MIC_KEY } from "../settings.js";
import type { AudioDevice } from "../audio/index.js";

export type ControllerMode = "grid" | "cmd" | "logs" | "settings" | "commands";

/* Command-mode key indices. Named because three of them are also handled in
 * `handleReport`'s key-up pass, and a bare number there silently drifts from
 * the face `surface.ts` paints on the same key. */
export const CMD_PAUSE = 0;
export const CMD_LOGS = 1;
export const CMD_MIC = 2;
export const CMD_SETTINGS = 3;
export const CMD_COMMANDS = 4;
export const CMD_SEND = 5;
export const CMD_CANCEL = 6;
/* The last cmd slot is Implement, and only for a ticket with no agent: the
 * surface paints it there from the same `agentLess` predicate this press reads,
 * so a press can never mean something the key does not say. */
export const CMD_IMPLEMENT = 7;

/* Settings-mode key indices. TestMic shares `CMD_MIC`'s slot so hold-to-talk is
 * under the same finger on both surfaces; the microphones fill what is left, in
 * the order `MIC_KEY_INDICES` gives. Those come from `settings.ts` so this
 * handler and the face `surface.ts` paints read one mapping, not two. */
export const SETTINGS_TEST_MIC = SETTINGS_TEST_MIC_KEY;
export const SETTINGS_NEXT_PAGE = SETTINGS_NEXT_PAGE_KEY;

/* Commands-mode key indices. Option slots and the mic/approve/cancel/paging
 * slots are shared with `commands.ts` so the key face and the press cannot
 * drift. */
export const COMMANDS_OPTION_SLOTS = OPTIONS_PER_PAGE;
export const COMMANDS_MIC = COMMANDS_MIC_SLOT;
export const COMMANDS_APPROVE = COMMANDS_APPROVE_SLOT;
export const COMMANDS_CANCEL = COMMANDS_CANCEL_SLOT;
export const COMMANDS_MORE = COMMANDS_MORE_SLOT;

/**
 * What the controller needs from the host's voice stack.
 *
 * A port rather than the `VoiceSession` itself, because the controller also
 * drives microphone discovery and the remembered choice, which are three
 * different objects in `src/audio/`. Absent on a host with no audio, and every
 * call site tolerates that — the deck still pages, focuses and reads logs on a
 * machine with no `parec`.
 */
export interface ControllerVoice {
  /** Begins capture. Idempotent. */
  hold(): void;
  /** Ends capture, keeping settled text. Idempotent. */
  release(): void;
  /** Settled text to deliver to the agent. */
  message(): string;
  hasMessage(): boolean;
  /** Discards the buffer. */
  clear(): void;
  /** Stops capture and drops any open provider session. */
  dispose(): void;
  /** Microphones detected at the last enumeration. */
  microphones(): readonly AudioDevice[];
  /** Re-enumerates. Called when the settings surface opens, and only there. */
  refresh(): void;
  selectedDeviceId(): string | null;
  select(deviceId: string): void;
}

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

export const asString = (value: unknown, fallback = ""): string => (typeof value === "string" ? value : fallback);
export const asNumber = (value: unknown): number => (typeof value === "number" && Number.isFinite(value) ? value : 0);
/** Empty strings are absent values here: the daemon omits, rather than blanks, a missing diff line. */
export const asText = (value: unknown): string | null => (typeof value === "string" && value !== "" ? value : null);

/** Normalises one server transcript row into a {@link TranscriptRow}. */
/**
 * Anything that is not a unified-diff marker is context. Passing an arbitrary
 * string through as a sign would let the feed pick the row's colour, and the
 * added/removed tint is the one thing a diff row's colour has to mean.
 */
export const toDiffSign = (value: unknown): DiffLine["sign"] => {
  const sign = asString(value, " ");
  return sign === "+" || sign === "-" ? sign : " ";
};

export const toTranscriptRow = (entry: Readonly<Record<string, unknown>>): TranscriptRow => {
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
export const toEventKey = (event: Readonly<Record<string, unknown>>): EventKey => ({
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
  /** First microphone shown on the settings surface; key 7 pages it. */
  readonly micOffset: number;
  /** The remembered microphone, re-read from the store after each selection. */
  readonly selectedMicId: string | null;
  /**
   * True while the voice buffer holds settled text.
   *
   * Mirrored into controller state rather than read live by the surface,
   * because it decides whether the Send and Cancel *keys exist* — and a key
   * appearing or disappearing has to go through the same publish/diff path as
   * every other key change, or the deck keeps painting keys that are gone.
   */
  readonly hasTranscript: boolean;
  /** The focused agent's Command history, from the last `commands` push. */
  readonly commandsPage: StreamDeckCommandsPage;
  /** Whether the Commands page is showing history or one Command's detail. */
  readonly commandsView: "history" | "detail";
  /** First Command shown on the history window; dial D pages it. */
  readonly historyOffset: number;
  /** Index into the history window of the focused key, or null. */
  readonly historySelection: number | null;
  /** The Command the detail view is reading, or null on the history view. */
  readonly selectedCommand: StreamDeckCommand | null;
  /** First option shown on the detail window; dial D pages it. */
  readonly optionOffset: number;
  /** Index into the selected Command's options, or null when none is selected. */
  readonly selectedOption: number | null;
  /** True while the Commands dictation buffer holds settled text. */
  readonly commandDictation: boolean;
  /** An answer error from the channel, shown on the detail strip. */
  readonly commandsError: string | null;
  /**
   * True from a successful Implement press until the next grid push.
   *
   * It only changes the Implement key's sub-label to `QUEUED`. Nothing here
   * pretends the ticket is running: the daemon decides when it dispatches, and
   * the running face arrives with the snapshot that says so.
   */
  readonly implementQueued: boolean;
}

export interface PhysicalControllerOptions {
  grid(): StreamDeckGrid;
  channel(): Pick<StreamDeckChannel, "focus" | "control" | "say" | "commandsPage" | "answerCommand"> | null;
  /** The voice stack, or null on a host with no audio. */
  voice?(): ControllerVoice | null;
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

export const initialState: ControllerState = {
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
  micOffset: 0,
  selectedMicId: null,
  hasTranscript: false,
  commandsPage: { items: [] },
  commandsView: "history",
  historyOffset: 0,
  historySelection: null,
  selectedCommand: null,
  optionOffset: 0,
  selectedOption: null,
  commandDictation: false,
  commandsError: null,
  implementQueued: false,
};

export const agentAt = (grid: StreamDeckGrid, offset: number, key: number): Readonly<Record<string, unknown>> | undefined =>
  grid.agents[agentIndexForKey(offset, key)];

export const identifierOf = (agent: Readonly<Record<string, unknown>> | undefined): string | null =>
  typeof agent?.identifier === "string" ? agent.identifier : null;

/**
 * What the controller's parts share. `state` is read through this object on
 * every use and replaced only by `publish`, so no part ever holds a stale copy.
 */
export interface ControllerCore {
  readonly state: ControllerState;
  readonly options: PhysicalControllerOptions;
  publish(next: ControllerState): void;
}

/** Wire types of the `streamdeck:fleet` channel contract; re-exported from `channel.ts`. */

export interface StreamDeckAgentState {
  readonly identifier: string;
  readonly status?: string;
  readonly title?: string;
  readonly priority?: boolean;
  readonly work_state?: string;
  readonly pause_reason?: string;
  readonly tracker_paused?: boolean;
}

/**
 * Whether Aiur can transcribe, and why not when it cannot.
 *
 * The API key lives in Aiur, so the sidecar cannot know this by inspecting its
 * own configuration — there is deliberately nothing in it to inspect. The
 * answer arrives with the snapshot, and the deck shows the reason while its
 * meters keep working.
 */
export interface StreamDeckVoiceState {
  readonly available: boolean;
  readonly reason: string | null;
}

export interface StreamDeckSnapshot {
  readonly version: number;
  readonly fleet: { readonly agents: readonly StreamDeckAgentState[] };
  readonly usage: Readonly<Record<string, unknown>>;
  readonly decisions: Readonly<Record<string, unknown>>;
  readonly grid?: StreamDeckGrid;
  readonly voice?: StreamDeckVoiceState;
}

export interface StreamDeckGrid {
  readonly agents: readonly Record<string, unknown>[];
  readonly total: number;
  readonly windows: number;
  readonly max_column_offset: number;
}

/**
 * One row of the flattened transcript, in the daemon's shape.
 *
 * `StreamdeckLogs.flatten/1` emits three of these — an `event_header` followed
 * by that event's `diff` and `message` entries, newest event first. Only
 * `message` carries a body, so collapsing every row to one display string
 * printed the literal "[INFO]" for each diff (whose text is its path and its
 * +/- counts) and discarded the badge that marks where an event begins. The
 * headers are also the jump targets for the log keys, so they have to survive
 * the trip to the renderer.
 */
/** One line of a unified diff, as the feed carries it. */
export interface DiffLine {
  /** `+` added, `-` removed, ` ` context. */
  readonly sign: "+" | "-" | " ";
  readonly text: string;
}

export type TranscriptRow =
  | {
      readonly kind: "event_header";
      /** Direction badge: EMIT, CONSUME, INFO, AGENT or SYSTEM. */
      readonly badge: string;
      readonly body: string;
      /** Human topic name — "PR merged", "Progress check-in", "Ticket opened". */
      readonly label: string;
      /** ISO instant the event was published; null when the feed omits one. */
      readonly timestamp: string | null;
    }
  | {
      readonly kind: "diff";
      readonly path: string;
      readonly additions: number;
      readonly deletions: number;
      /** First changed line of the hunk; null for a summary-only diff. */
      readonly line: string | null;
    }
  | {
      /**
       * One line of the hunk above it.
       *
       * The feed unrolls a diff into a header row followed by one of these per
       * line, rather than packing the hunk into a single row. The client
       * addresses transcript rows by index — to scroll, and to jump the log
       * keys — so a row that painted three lines would move the readout three
       * rows for one detent.
       */
      readonly kind: "diff_line";
      readonly sign: "+" | "-" | " ";
      readonly text: string;
    }
  | {
      readonly kind: "message";
      readonly role: string;
      readonly body: string;
      /** Tool name for a `tool` role, when the provider named one. */
      readonly tool: string | null;
      /**
       * Colour class for the row, mirroring the server's `StreamdeckLogs.row_kind/1`
       * so the physical deck and the emulator agree. Absent for a row that did
       * not carry one (a live push, a legacy DTO); the renderer derives it from
       * `role`.
       */
      readonly rowKind?: ChatKind;
      /** opencode-style gutter glyph (`$`, `→`, `←`, `⚙`); absent for prose. */
      readonly glyph?: string | null;
    };

/**
 * The three visually-distinct row classes plus the rare user turn. Commands
 * and tool rows share the command colour; agent prose is its own class; system
 * context rows (event headers, diffs, logs) are the third. Mirrors the server's
 * `StreamdeckLogs.row_kind/1` so the physical deck matches the emulator.
 */
export type ChatKind = "command" | "agent" | "logs" | "user";

export interface StreamDeckLogs {
  readonly event_keys?: readonly Record<string, unknown>[];
  readonly event_keys_visible?: readonly Record<string, unknown>[];
  readonly transcript?: readonly Record<string, unknown>[];
  readonly events_offset?: number;
  readonly events_max_offset?: number;
  readonly transcript_offset?: number;
  readonly transcript_max_offset?: number;
}

/**
 * One option of a Command, in the daemon's allowlisted shape.
 *
 * The server projects only the option fields the device renders (id, label,
 * description and the cost/benefit detail), never internal store fields.
 */
export interface StreamDeckCommandOption {
  readonly id: string;
  readonly label: string;
  readonly description?: string;
  readonly benefits?: string;
  readonly drawbacks?: string;
  readonly risk?: string;
}

/** The recorded outcome of a Command, when it has one. */
export interface StreamDeckCommandAnswer {
  /** The chosen option id, when the answer selected a listed option. */
  readonly selected_option_id?: string | null;
  /** The free-text response, when the operator spoke instead of choosing. */
  readonly custom_response?: string | null;
  readonly actor?: { readonly kind?: string; readonly id?: string } | null;
}

/**
 * One Command in the focused agent's history, in the daemon's allowlisted
 * shape. `status` is the durable lifecycle (`open`, `deferred`, `decided`,
 * `acknowledged`, ...); only `open`/`deferred` are answerable, and `answer`
 * lets a completed Command be read back as what was asked and what was decided.
 */
export interface StreamDeckCommand {
  readonly decision_id: string;
  /** The exact version the device read — the version it must answer. */
  readonly version: number;
  readonly ticket?: { readonly identifier?: string } | null;
  readonly question: string;
  readonly context?: { readonly short?: string | null; readonly long?: string | null } | null;
  readonly options: readonly StreamDeckCommandOption[];
  readonly status: string;
  readonly answer?: StreamDeckCommandAnswer | null;
  readonly created_at?: string;
}

/**
 * One page of the focused agent's Command history.
 *
 * History is newest-first and cursor-paged: the server pushes the first page on
 * focus and the client requests more with `commands_page` when it scrolls past
 * the end. `unavailable` is explicit — the store could not be read — so the
 * device says so instead of showing an empty history that could mean "no
 * Commands".
 */
export interface StreamDeckCommandsPage {
  readonly identifier?: string;
  readonly items: readonly StreamDeckCommand[];
  readonly next_cursor?: string | null;
  readonly has_next?: boolean;
  readonly total?: number;
  readonly partial?: boolean;
  readonly unavailable?: boolean;
}

/** The channel's reply to `answer_command`. */
export interface StreamDeckCommandAnswerResult {
  readonly status: string;
  readonly decision: StreamDeckCommand;
}

export interface StreamDeckChannelEvents {
  snapshot(snapshot: StreamDeckSnapshot): void;
  fleet(agents: readonly StreamDeckAgentState[]): void;
  grid(grid: StreamDeckGrid): void;
  usage(usage: Readonly<Record<string, unknown>>): void;
  transcript(row: TranscriptRow): void;
  logs(logs: StreamDeckLogs): void;
  control(payload: Readonly<Record<string, unknown>>): void;
  /**
   * The reply to a {@link StreamDeckChannel.voiceStart}. Exactly one of the two
   * arguments is set: a server-minted session id, or the reason it was refused.
   */
  voiceStarted(session: string | null, reason: string | null): void;
  /** A `voice` push: one partial or final transcript for an open session. */
  voice(session: string, kind: "partial" | "final", text: string): void;
  voiceError(session: string, reason: string): void;
  voiceClosed(session: string): void;
  /** The snapshot's view of whether Aiur can transcribe at all. */
  voiceAvailability(state: StreamDeckVoiceState): void;
  /**
   * A `commands` push: the focused agent's Command history page. Sent on focus
   * and again whenever a decision for the focused agent changes.
   */
  commands(page: StreamDeckCommandsPage): void;
  /** The reply to `answer_command`: the recorded result and the refreshed Command. */
  commandAnswered(result: StreamDeckCommandAnswerResult): void;
  /** An error reply to `commands_page` or `answer_command`. */
  commandsError(reason: string): void;
  closed(error: unknown): void;
}

export interface WebSocketLike {
  binaryType: string;
  onopen: (() => void) | null;
  onmessage: ((event: { data: string }) => void) | null;
  onerror: ((error: unknown) => void) | null;
  onclose: (() => void) | null;
  send(data: string): void;
  close(): void;
}

export type WebSocketFactory = (url: string) => WebSocketLike;
export type FetchLike = (input: string, init?: { method?: string; headers?: Record<string, string>; body?: string }) => Promise<{
  ok: boolean;
  json(): Promise<unknown>;
}>;

export interface StreamDeckChannelOptions {
  readonly baseUrl: string;
  readonly username: string;
  readonly password: string;
  readonly fetch: FetchLike;
  readonly websocket: WebSocketFactory;
  readonly events: StreamDeckChannelEvents;
}

export interface StreamDeckChannel {
  focus(identifier: string): void;
  /**
   * The two fleet verbs the deck can perform.
   *
   * `prioritize`/`deprioritize` are gone with the key that sent them, and
   * `"mic"` was never a server action at all — the channel rejected it, so the
   * key had no effect. Voice has its own three events below.
   *
   * `implement` is the queue verb for a ticket with no agent: the server applies
   * the configured lifecycle todo label through the CLI's own `--todo` path, so
   * the deck asks for a dispatch rather than performing one.
   */
  control(identifier: string, action: "pause" | "resume" | "implement"): void;
  /**
   * Delivers a transcribed message to an agent.
   *
   * This is a separate event from `control` because it carries operator text
   * rather than a fixed verb: the server validates and length-caps it, then
   * hands it to the same AgentChat path as the dashboard chat box, so a spoken
   * message and a typed one are indistinguishable downstream.
   *
   * Each call is one press and carries its own `message_id`. A frame queued
   * before the join is re-sent with the same id, so a re-send cannot queue a
   * second copy (#2717). Two presses with the same text are two messages.
   */
  say(identifier: string, text: string): void;
  /**
   * Asks Aiur to open a provider session. The session id comes back in the
   * `phx_reply`, not in a push, so it is delivered through
   * {@link StreamDeckChannelEvents.voiceStarted}.
   */
  voiceStart(): void;
  /** One base64-encoded PCM frame. Fire-and-forget: the server does not reply. */
  voiceAudio(session: string, base64: string): void;
  /** Asks Aiur to commit the final utterance and close the provider session. */
  voiceStop(session: string): void;
  /**
   * Requests the next page of the focused agent's Command history.
   *
   * `cursor` is the opaque `next_cursor` from the previous page; the server
   * replies through {@link StreamDeckChannelEvents.commands} or
   * {@link StreamDeckChannelEvents.commandsError}.
   */
  commandsPage(cursor: string): void;
  /**
   * Records an operator answer given on the device.
   *
   * The answer is attributed to the operator (never the Executor), so it may
   * answer `human_required` Commands. `idempotencyKey` must be stable for the
   * same intended answer across reconnects: the server deduplicates on it, so
   * a retry after a dropped reply is a replay, never a second decision.
   * `version` is the exact Command version the device read.
   */
  answerCommand(
    decisionId: string,
    version: number,
    idempotencyKey: string,
    answer: { option_id?: string; custom_response?: string },
  ): void;
  close(): void;
}

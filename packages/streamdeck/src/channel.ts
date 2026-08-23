/**
 * Small Phoenix channel client used by the physical sidecar.
 *
 * The browser emulator and this client deliberately share the server channel
 * contract. The sidecar never talks to internal PubSub topics and never
 * reimplements orchestrator controls: it receives projected state and sends
 * `control` through the authenticated channel.
 *
 * ## Why captured audio travels as base64 inside a JSON frame
 *
 * This client is a hand-rolled Phoenix v2 serializer whose frames are JSON
 * arrays `[join_ref, ref, topic, event, payload]`. Phoenix's *binary* path
 * carries a raw payload with **no event name**, so a binary frame cannot be
 * routed alongside `focus` / `control` / `say` on this topic — it would need a
 * second socket with its own token, its own join and its own reconnect. That
 * cost buys nothing, because:
 *
 *   - ElevenLabs' realtime protocol is *itself* base64-in-JSON: the provider
 *     frame is `{message_type, audio_base_64, commit, sample_rate}`. Aiur
 *     forwards the string this client produced verbatim, doing **zero
 *     transcode**.
 *   - The 4/3 expansion is therefore paid exactly once, on a leg that would pay
 *     it anyway. A binary channel frame would only move the cost to Aiur, which
 *     would then have to base64-encode before forwarding.
 *
 * Measured: capture is 32,000 B/s (16 kHz mono s16le) regrouped into 3,200-byte
 * frames, so 10 messages/s of 4,272 base64 chars plus ~60 bytes of framing —
 * about 43.3 kB/s, of which framing is 1.4%. **Do not add binary-frame
 * support.**
 */

import { normalizeAiurDictation } from "./aiur-speech.js";

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

/** Derives the row class from a role, for a row that did not carry one. */
export const rowKindOfRole = (role: string): ChatKind => {
  if (role === "assistant" || role === "agent") return "agent";
  if (role === "command" || role === "tool") return "command";
  if (role === "user") return "user";
  // system, reasoning, alert, ci and anything unknown are the "logs" class —
  // the same mapping as the server's `StreamdeckLogs.row_kind/1`.
  return "logs";
};

export const chatKind = (value: unknown): ChatKind => {
  if (value === "command" || value === "agent" || value === "logs" || value === "user") return value;
  return "logs";
};

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
   */
  control(identifier: string, action: "pause" | "resume"): void;
  /**
   * Delivers a transcribed message to an agent.
   *
   * This is a separate event from `control` because it carries operator text
   * rather than a fixed verb: the server validates and length-caps it, then
   * hands it to the same AgentChat path as the dashboard chat box, so a spoken
   * message and a typed one are indistinguishable downstream.
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

const tokenPath = "/api/v1/streamdeck/token";

const channelUrl = (baseUrl: string, token: string): string => {
  const url = new URL(baseUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = "/streamdeck/websocket";
  url.search = new URLSearchParams({ token, vsn: "2.0.0" }).toString();
  return url.toString();
};

const parseFrame = (data: string): unknown[] | null => {
  try {
    const value: unknown = JSON.parse(data);
    return Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
};

/** Connects and joins the authenticated `streamdeck:fleet` channel. */
export const connectStreamDeckChannel = async (options: StreamDeckChannelOptions): Promise<StreamDeckChannel> => {
  const response = await options.fetch(new URL(tokenPath, options.baseUrl).toString(), {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(`${options.username}:${options.password}`).toString("base64")}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!response.ok) throw new Error(`Stream Deck token request failed (${response.ok ? "ok" : "unauthorized"})`);
  const tokenPayload = (await response.json()) as { token?: unknown };
  if (typeof tokenPayload.token !== "string" || tokenPayload.token.length === 0) throw new Error("Stream Deck token response was invalid");

  const socket = options.websocket(channelUrl(options.baseUrl, tokenPayload.token));
  socket.binaryType = "arraybuffer";
  let reference = 0;
  let joined = false;
  let stopped = false;
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let closedNotified = false;
  const pending: Array<{ event: string; payload: Record<string, unknown> }> = [];
  /**
   * The join's own ref, so a reply can be told apart from every other reply.
   *
   * Before voice, any `{status: "ok"}` reply meant "the join succeeded", which
   * worked only because nothing else on this topic was ever replied to. Now
   * `voice_start` is, and treating its reply as the join would flush the queue a
   * second time and re-send whatever was in it.
   */
  let joinRef: string | null = null;
  /** Refs of `voice_start` requests still waiting for their reply. */
  const voiceStartRefs = new Set<string>();
  /** Refs of `commands_page` requests still waiting for their reply. */
  const commandsPageRefs = new Set<string>();
  /** Refs of `answer_command` requests still waiting for their reply. */
  const answerCommandRefs = new Set<string>();
  const send = (event: string, payload: Record<string, unknown>): void => {
    if (!joined) {
      pending.push({ event, payload });
      return;
    }
    // The ref is captured here rather than at the call site because a command
    // sent before the join is re-sent from `pending` and gets its ref then.
    const ref = String(++reference);
    if (event === "voice_start") voiceStartRefs.add(ref);
    else if (event === "commands_page") commandsPageRefs.add(ref);
    else if (event === "answer_command") answerCommandRefs.add(ref);
    socket.send(JSON.stringify(["4", ref, "streamdeck:fleet", event, payload]));
  };

  socket.onopen = () => {
    joinRef = String(++reference);
    socket.send(JSON.stringify(["4", joinRef, "streamdeck:fleet", "phx_join", {}]));
    heartbeat = setInterval(() => {
      if (!stopped) socket.send(JSON.stringify(["4", String(++reference), "phoenix", "heartbeat", {}]));
    }, 30_000);
  };
  socket.onmessage = ({ data }) => {
    const frame = parseFrame(data);
    if (frame === null) return;
    const event = frame[3];
    const payload = frame[4];
    if (event === "phx_reply") {
      const ref = typeof frame[1] === "string" ? frame[1] : "";
      const reply = payload as { status?: unknown; response?: unknown } | undefined;
      const response = (typeof reply?.response === "object" && reply.response !== null ? reply.response : {}) as Record<string, unknown>;
      if (voiceStartRefs.delete(ref)) {
        if (reply?.status === "ok" && typeof response.session === "string") {
          options.events.voiceStarted(response.session, null);
        } else {
          options.events.voiceStarted(null, typeof response.reason === "string" ? response.reason : null);
        }
        return;
      }
      if (commandsPageRefs.delete(ref)) {
        if (reply?.status === "ok" && Array.isArray(response.items)) {
          options.events.commands(response as unknown as StreamDeckCommandsPage);
        } else {
          options.events.commandsError(typeof response.reason === "string" ? response.reason : "Commands page failed");
        }
        return;
      }
      if (answerCommandRefs.delete(ref)) {
        if (reply?.status === "ok" && typeof response.decision === "object" && response.decision !== null) {
          options.events.commandAnswered({
            status: typeof response.status === "string" ? response.status : "accepted",
            decision: response.decision as unknown as StreamDeckCommand,
          });
        } else {
          options.events.commandsError(typeof response.reason === "string" ? response.reason : "Answer failed");
        }
        return;
      }
      // Unchanged join behaviour, now addressed by ref. `joinRef === null`
      // covers a server that replies before `onopen` ran, which the original
      // any-ok-reply rule accepted and which nothing should start rejecting.
      if (reply?.status === "ok" && (joinRef === null || ref === joinRef)) {
        joined = true;
        for (const command of pending.splice(0)) send(command.event, command.payload);
      }
      return;
    }
    if (event === "phx_close" || event === "phx_error") {
      notifyClosed(new Error(`Stream Deck channel ${event}`));
      return;
    }
    if (typeof event !== "string" || typeof payload !== "object" || payload === null) return;
    if (event === "snapshot") {
      const snapshot = payload as StreamDeckSnapshot;
      if (snapshot.grid !== undefined) options.events.grid(snapshot.grid);
      // A daemon older than this sidecar sends no `voice` entry at all. That is
      // read as unavailable-with-no-reason rather than as available: opening a
      // hold against a server that cannot serve it would leave the operator
      // talking into a socket that answers nothing.
      const voice = snapshot.voice;
      options.events.voiceAvailability({
        available: voice?.available === true,
        reason: typeof voice?.reason === "string" ? voice.reason : null,
      });
      options.events.snapshot(snapshot);
    }
    else if (event === "fleet") {
      const fleet = payload as { agents?: readonly StreamDeckAgentState[]; grid?: StreamDeckGrid };
      options.events.fleet(fleet.agents ?? []);
      if (fleet.grid !== undefined) options.events.grid(fleet.grid);
    }
    else if (event === "usage") options.events.usage(payload as Readonly<Record<string, unknown>>);
    else if (event === "transcript") {
      // The live per-message push is the same shape as a flattened `message`
      // row, so it enters the transcript as one rather than as a bare string:
      // the strip renders the speaker, and the row cannot be mistaken for the
      // event header the log keys jump to.
      const message = payload as { role?: unknown; body?: unknown };
      options.events.transcript({
        kind: "message",
        role: typeof message.role === "string" ? message.role : "agent",
        body: typeof message.body === "string" ? message.body : "",
        tool: null,
      });
    }
    else if (event === "logs") options.events.logs(payload as StreamDeckLogs);
    else if (event === "control") options.events.control(payload as Readonly<Record<string, unknown>>);
    else if (event === "voice") {
      const frame = payload as { session?: unknown; kind?: unknown; text?: unknown };
      // `final_transcript` is still revisable upstream, so anything that is not
      // explicitly final is treated as a partial — the conservative direction,
      // because a partial is replaced in the buffer and a final is kept.
      options.events.voice(
        typeof frame.session === "string" ? frame.session : "",
        frame.kind === "final" ? "final" : "partial",
        typeof frame.text === "string" ? normalizeAiurDictation(frame.text) : "",
      );
    }
    else if (event === "voice_error") {
      const frame = payload as { session?: unknown; reason?: unknown };
      options.events.voiceError(
        typeof frame.session === "string" ? frame.session : "",
        typeof frame.reason === "string" ? frame.reason : "Transcription failed",
      );
    }
    else if (event === "voice_closed") {
      const frame = payload as { session?: unknown };
      options.events.voiceClosed(typeof frame.session === "string" ? frame.session : "");
    }
    else if (event === "commands") {
      options.events.commands(payload as StreamDeckCommandsPage);
    }
  };
  const notifyClosed = (error: unknown): void => {
    if (heartbeat !== null) clearInterval(heartbeat);
    heartbeat = null;
    if (!stopped && !closedNotified) {
      closedNotified = true;
      socket.close();
      options.events.closed(error);
    }
  };
  socket.onerror = (error) => notifyClosed(error);
  socket.onclose = () => notifyClosed(new Error("Stream Deck channel closed"));

  return {
    focus: (identifier) => send("focus", { identifier }),
    control: (identifier, action) => send("control", { identifier, action }),
    say: (identifier, text) => send("say", { identifier, text }),
    voiceStart: () => send("voice_start", {}),
    voiceAudio: (session, base64) => send("voice_audio", { session, audio: base64 }),
    voiceStop: (session) => send("voice_stop", { session }),
    commandsPage: (cursor) => send("commands_page", { cursor }),
    answerCommand: (decisionId, version, idempotencyKey, answer) =>
      send("answer_command", { decision_id: decisionId, version, idempotency_key: idempotencyKey, ...answer }),
    close: () => {
      stopped = true;
      joined = false;
      voiceStartRefs.clear();
      commandsPageRefs.clear();
      answerCommandRefs.clear();
      if (heartbeat !== null) clearInterval(heartbeat);
      heartbeat = null;
      socket.close();
    },
  };
};

export const defaultWebSocket: WebSocketFactory = (url) => new WebSocket(url) as unknown as WebSocketLike;
export const defaultFetch: FetchLike = (input, init) => fetch(input, init) as Promise<Awaited<ReturnType<FetchLike>>>;

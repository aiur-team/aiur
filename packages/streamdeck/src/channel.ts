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

import { randomUUID } from "node:crypto";

import { normalizeAiurDictation } from "./aiur-speech.js";

import type {
  ChatKind,
  FetchLike,
  StreamDeckAgentState,
  StreamDeckChannel,
  StreamDeckChannelOptions,
  StreamDeckCommand,
  StreamDeckCommandsPage,
  StreamDeckGrid,
  StreamDeckLogs,
  StreamDeckSnapshot,
  WebSocketFactory,
  WebSocketLike,
} from "./channel-types.js";

export type * from "./channel-types.js";

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
    say: (identifier, text) => send("say", { identifier, text, message_id: randomUUID() }),
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

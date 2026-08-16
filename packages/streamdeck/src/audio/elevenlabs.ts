/**
 * ElevenLabs realtime speech-to-text, behind the provider-agnostic contract.
 *
 * ElevenLabs exposes a genuine bidirectional websocket for transcription
 * (`scribe_v2_realtime`), so audio streams as it is captured and partial text
 * comes back in roughly 150 ms. Batching short clips through the file endpoint
 * would add a round trip per utterance and could not drive a live readout at
 * all, so the websocket is the path taken here.
 *
 * Protocol reference:
 * https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
 *
 * The API key travels as a request header, never in the URL, because a URL is
 * the thing that ends up in logs and error messages. ElevenLabs also accepts a
 * single-use `token` query parameter, but that is the *browser* answer: it
 * still puts a credential in a URL, and being consumed on use it would force a
 * REST round trip before every reconnect. Nothing here prints the key.
 */

import type { SocketFactory, Transcriber, TranscriberHandlers, TranscriberSession } from "./stt.js";

export const ELEVENLABS_REALTIME_URL = "wss://api.elevenlabs.io/v1/speech-to-text/realtime";
export const ELEVENLABS_REALTIME_MODEL = "scribe_v2_realtime";

/**
 * How long to wait for the server to settle the final utterance after the
 * commit flush before giving up and closing anyway. Injectable so tests drive
 * it by hand rather than by elapsed time.
 */
export const FLUSH_TIMEOUT_MS = 2_000;

/** Injectable one-shot timer, matching `capture.ts` so hosts wire one clock. */
export type Scheduler = (callback: () => void, delayMs: number) => { cancel(): void };

const defaultScheduler: Scheduler = (callback, delayMs) => {
  const handle = setTimeout(callback, delayMs);
  handle.unref();
  return { cancel: () => clearTimeout(handle) };
};

export interface ElevenLabsTranscriberOptions {
  readonly apiKey: string;
  readonly socket: SocketFactory;
  /** Must match the capture format; 16 kHz mono is what capture produces. */
  readonly sampleRate?: number;
  /** ISO-639-3. English is "eng". */
  readonly languageCode?: string;
  readonly baseUrl?: string;
  readonly flushTimeoutMs?: number;
  readonly scheduler?: Scheduler;
  /** Injected so tests encode without depending on Node's Buffer. */
  readonly encodeBase64?: (bytes: Uint8Array) => string;
}

interface RealtimeMessage {
  readonly message_type?: unknown;
  readonly text?: unknown;
  readonly error?: unknown;
}

const defaultBase64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString("base64");

/** Only `pcm_<rate>` rates ElevenLabs documents; capture uses 16 kHz. */
const audioFormatFor = (sampleRate: number): string => `pcm_${sampleRate}`;

const realtimeUrl = (baseUrl: string, sampleRate: number, languageCode: string): string => {
  const url = new URL(baseUrl);
  url.searchParams.set("model_id", ELEVENLABS_REALTIME_MODEL);
  url.searchParams.set("audio_format", audioFormatFor(sampleRate));
  url.searchParams.set("language_code", languageCode);
  // Voice activity detection commits an utterance on a natural pause, which is
  // what makes text settle while the operator is still holding the key.
  url.searchParams.set("commit_strategy", "vad");
  return url.toString();
};

/**
 * `committed_transcript` is the authoritative settled text. `final_transcript`
 * is still revisable despite its name, so it is treated as a partial — keeping
 * it would duplicate phrases in the operator's outgoing message.
 */
const FINAL_TYPES: ReadonlySet<string> = new Set([
  "committed_transcript",
  "committed_transcript_with_timestamps",
]);
const PARTIAL_TYPES: ReadonlySet<string> = new Set([
  "partial_transcript",
  "final_transcript",
  "final_transcript_with_timestamps",
]);

/**
 * The documented error frames, matched as an explicit set.
 *
 * A `*_error` suffix heuristic looks tempting and is wrong: it silently misses
 * `error`, `invalid_request`, `quota_exceeded`, `rate_limited` and the rest,
 * which would leave a dead session looking merely quiet.
 */
const ERROR_TYPES: ReadonlySet<string> = new Set([
  "error",
  "auth_error",
  "quota_exceeded",
  "commit_throttled",
  "unaccepted_terms",
  "rate_limited",
  "queue_overflow",
  "resource_exhausted",
  "session_time_limit_exceeded",
  "input_error",
  "invalid_request",
  "chunk_size_exceeded",
  "insufficient_audio_activity",
  "transcriber_error",
]);

export function createElevenLabsTranscriber(options: ElevenLabsTranscriberOptions): Transcriber {
  const sampleRate = options.sampleRate ?? 16_000;
  const languageCode = options.languageCode ?? "eng";
  const encodeBase64 = options.encodeBase64 ?? defaultBase64;
  const scheduler = options.scheduler ?? defaultScheduler;
  const url = realtimeUrl(options.baseUrl ?? ELEVENLABS_REALTIME_URL, sampleRate, languageCode);

  return {
    available: true,
    unavailableReason: null,
    open(handlers: TranscriberHandlers): TranscriberSession {
      const socket = options.socket(url, { "xi-api-key": options.apiKey });
      // Audio captured before the server reports `session_started` would be
      // discarded, so it queues here and flushes on that frame. Losing the
      // first word of every hold is exactly what makes voice input feel
      // unreliable, and the socket being open is not the same as the session
      // being ready.
      let ready = false;
      let closed = false;
      let flushDeadline: { cancel(): void } | null = null;
      const backlog: string[] = [];

      const finish = (): void => {
        if (closed) return;
        closed = true;
        flushDeadline?.cancel();
        flushDeadline = null;
        socket.close();
      };

      const fail = (reason: string): void => {
        if (closed) return;
        // Seal before notifying, not after. The voice session's `onError`
        // synchronously calls `close()` on this session; while the session is
        // still open that reentrant call sends a commit flush frame on a
        // connection that has just failed, and arms a flush deadline that
        // `finish()` then immediately cancels.
        finish();
        handlers.onError(reason);
      };

      const transmit = (audioBase64: string, commit: boolean): void => {
        socket.send(
          JSON.stringify({
            message_type: "input_audio_chunk",
            audio_base_64: audioBase64,
            commit,
            sample_rate: sampleRate,
          }),
        );
      };

      socket.onopen = (): void => {
        // Deliberately empty: readiness is `session_started`, not the upgrade.
      };

      socket.onmessage = (event: { data: string }): void => {
        let message: RealtimeMessage;
        try {
          message = JSON.parse(event.data) as RealtimeMessage;
        } catch {
          // A malformed frame is the provider's problem, not a reason to tear
          // down a working session; the next frame usually parses.
          return;
        }
        const type = typeof message.message_type === "string" ? message.message_type : "";
        const text = typeof message.text === "string" ? message.text : "";

        if (type === "session_started") {
          ready = true;
          for (const chunk of backlog) transmit(chunk, false);
          backlog.length = 0;
          return;
        }
        if (FINAL_TYPES.has(type)) {
          handlers.onTranscript({ kind: "final", text });
          // The settled utterance we were waiting for after the commit flush;
          // closing before it arrived is what clipped the last words.
          if (flushDeadline !== null) finish();
          return;
        }
        if (PARTIAL_TYPES.has(type)) {
          handlers.onTranscript({ kind: "partial", text });
          return;
        }
        if (ERROR_TYPES.has(type)) fail(describeFailure(type, message.error));
      };

      socket.onerror = (): void => {
        // The underlying error object can embed request headers, so it is
        // described generically rather than interpolated — the API key must
        // never reach a log line.
        fail("Speech-to-text connection failed");
      };

      socket.onclose = (): void => {
        closed = true;
        flushDeadline?.cancel();
        flushDeadline = null;
      };

      return {
        push(pcm: Uint8Array): void {
          // Once flushing, the utterance is sealed; more audio would reopen it.
          if (closed || flushDeadline !== null) return;
          const encoded = encodeBase64(pcm);
          if (ready) {
            transmit(encoded, false);
            return;
          }
          backlog.push(encoded);
        },
        close(): void {
          if (closed || flushDeadline !== null) return;
          // Nothing was ever sent, so there is nothing to settle.
          if (!ready) {
            finish();
            return;
          }
          // An empty chunk with `commit` set is the documented way to seal the
          // final utterance. Closing the socket without it drops whatever the
          // server had not yet committed — the tail of what was just said.
          transmit("", true);
          flushDeadline = scheduler(finish, options.flushTimeoutMs ?? FLUSH_TIMEOUT_MS);
        },
      };
    },
  };
}

/** Turns a provider error frame into something an operator can act on. */
function describeFailure(type: string, detail: unknown): string {
  if (type === "auth_error") return "ElevenLabs rejected the API key";
  if (type === "quota_exceeded") return "ElevenLabs quota exhausted";
  if (type === "rate_limited" || type === "commit_throttled") return "ElevenLabs rate limit reached";
  if (type === "unaccepted_terms") return "ElevenLabs terms not accepted for this account";
  if (type === "session_time_limit_exceeded") return "ElevenLabs session time limit reached";
  return typeof detail === "string" && detail !== "" ? detail : "Speech-to-text failed";
}

/**
 * The transcriber that relays audio to Aiur instead of calling a provider.
 *
 * The operator's decision is that **Aiur performs the ElevenLabs call**. So the
 * sidecar holds no `ELEVENLABS_API_KEY` — not in its process, its environment
 * or its config — and this module holds no URL, no header and no protocol. It
 * pushes captured frames at a `VoiceRelayPort` the host supplies and waits for
 * the host to hand transcripts back. Everything provider-shaped lives in Aiur.
 *
 * ## Why audio travels as base64 inside JSON
 *
 * The sidecar's channel client is a hand-rolled Phoenix v2 serializer whose
 * frames are JSON arrays `[join_ref, ref, topic, event, payload]`. Phoenix's
 * binary path carries a raw payload with **no event name**, so a binary frame
 * cannot be routed alongside `focus`/`control`/`say` without a second socket
 * carrying its own auth and its own reconnect. That cost buys nothing, because
 * ElevenLabs' own realtime protocol is *already* base64-in-JSON: the provider
 * frame is `{message_type: "input_audio_chunk", audio_base_64, commit,
 * sample_rate}`. Relaying the base64 string verbatim means Aiur does **zero
 * transcode** — the string produced here is the string the provider receives.
 *
 * The 4/3 expansion is therefore paid exactly once, on a leg that would pay it
 * anyway. A binary channel frame would only move the cost to Aiur, which would
 * have to base64-encode before forwarding.
 *
 * Measured budget: capture is 32,000 B/s (16 kHz mono s16le). `aggregate.ts`
 * regroups it into `TARGET_FRAME_BYTES` = 3,200 (100 ms), so **10 messages/s**,
 * each 4,272 base64 chars plus ~60 bytes of Phoenix framing — about
 * **43.3 kB/s**, of which framing is 1.4%.
 *
 * There is no timer and no clock here. Everything advances on a captured frame
 * or on a push from Aiur, so a test drives a whole session by hand.
 */

import {
  createUnavailableTranscriber,
  type Transcriber,
  type TranscriberHandlers,
  type TranscriberSession,
  type TranscriptEvent,
} from "./stt.js";

/** What the host gives the relay so it can reach Aiur. */
export interface VoiceRelayPort {
  /** Ask Aiur to open a provider session. */
  start(): void;
  /** One base64-encoded PCM frame. */
  audio(base64: string): void;
  /** Ask Aiur to commit the final utterance and close. */
  stop(): void;
}

export interface RelayTranscriberOptions {
  readonly port: VoiceRelayPort;
  /** Injected so tests encode without depending on Node's Buffer. */
  readonly encodeBase64?: (bytes: Uint8Array) => string;
  /** Non-null when Aiur reports voice is not configured; the reason is shown. */
  readonly unavailableReason?: string | null;
}

export interface RelayTranscriber {
  readonly transcriber: Transcriber;
  /** Host calls this for each `voice` push from Aiur. */
  deliver(event: TranscriptEvent): void;
  /** Host calls this for a `voice_error` push, or when the channel drops. */
  fail(reason: string): void;
  /** Host calls this for a `voice_closed` push. */
  finish(): void;
}

const defaultBase64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString("base64");

/** The no-op relay handed back when transcription is unavailable. */
const IDLE_RELAY = { deliver: () => {}, fail: () => {}, finish: () => {} };

export function createRelayTranscriber(options: RelayTranscriberOptions): RelayTranscriber {
  const reason = options.unavailableReason ?? "";
  if (reason !== "") {
    // Delegated rather than restated: the degraded behaviour — a printable
    // reason, `onError` on open, and a session that never touches the port —
    // has exactly one definition, in `stt.ts`.
    return { transcriber: createUnavailableTranscriber(reason), ...IDLE_RELAY };
  }

  const encodeBase64 = options.encodeBase64 ?? defaultBase64;
  const port = options.port;

  // Only one hold is live at a time. Frames that arrive outside it are dropped,
  // which is what stops a late transcript from a previous hold landing in the
  // buffer of the current one.
  let live: {
    readonly handlers: TranscriberHandlers;
    sealed: boolean;
  } | null = null;

  return {
    transcriber: {
      available: true,
      unavailableReason: null,
      open(handlers: TranscriberHandlers): TranscriberSession {
        const session = { handlers, sealed: false };
        live = session;
        port.start();

        return {
          push(pcm: Uint8Array): void {
            if (session.sealed) return;
            port.audio(encodeBase64(pcm));
          },
          close(): void {
            if (session.sealed) return;
            session.sealed = true;
            if (live === session) live = null;
            port.stop();
          },
        };
      },
    },

    deliver(event: TranscriptEvent): void {
      live?.handlers.onTranscript(event);
    },

    fail(failureReason: string): void {
      const session = live;
      if (session === null) return;
      // Seal before notifying, not after. `session.ts`'s `onError` handler
      // synchronously calls `close()` on this session; while the session is
      // still open that reentrant call sends a `stop` on a connection that has
      // just failed.
      session.sealed = true;
      live = null;
      session.handlers.onError(failureReason);
    },

    finish(): void {
      if (live === null) return;
      live.sealed = true;
      live = null;
    },
  };
}

/**
 * The host side of voice: correlating a hold with a server-minted session, and
 * keeping a 50 Hz audio stream from driving a 50 Hz repaint.
 *
 * This lives outside `src/audio/` on purpose. The audio stack knows nothing
 * about Phoenix, and `main.ts` is the process entry point with no tests of its
 * own, so the two pieces of real logic between them — "which frames belong to
 * this hold?" and "how often may the strip repaint?" — are here, where they are
 * covered.
 *
 * Neither piece reads a clock of its own: the coalescer takes `now` and
 * `setTimer` as ports, so a test drives it by hand and nothing in the suite
 * waits on wall-clock time.
 */

import type { TranscriptEvent, VoiceRelayPort } from "./audio/index.js";

/** The subset of the channel client the link sends on. */
export interface VoiceLinkChannel {
  voiceStart(): void;
  voiceAudio(session: string, base64: string): void;
  voiceStop(session: string): void;
}

/** The subset of `RelayTranscriber` the link hands inbound frames to. */
export interface VoiceLinkRelay {
  deliver(event: TranscriptEvent): void;
  fail(reason: string): void;
  finish(): void;
}

export interface VoiceLinkOptions {
  /** The live channel, or null while disconnected. Read on every call. */
  channel(): VoiceLinkChannel | null;
  /** The current relay transcriber, or null before one is built. */
  relay(): VoiceLinkRelay | null;
}

export interface VoiceLink {
  /** Hand this to `createRelayTranscriber`. */
  readonly port: VoiceRelayPort;
  /** The reply to `voice_start`: a session id, or a refusal reason. */
  started(session: string | null, reason: string | null): void;
  /** A `voice` push. Ignored unless it names the session this hold opened. */
  transcript(session: string, event: TranscriptEvent): void;
  /** A `voice_error` push. */
  failed(session: string, reason: string): void;
  /** A `voice_closed` push. */
  closed(session: string): void;
  /** The channel dropped; abandon whatever hold was open. */
  drop(reason: string): void;
}

/** Shown when Aiur refuses `voice_start` without saying why. */
export const VOICE_START_REFUSED = "Aiur refused the voice session";

/** Shown when the channel drops mid-hold. */
export const VOICE_LINK_LOST = "Lost the connection to Aiur";

export function createVoiceLink(options: VoiceLinkOptions): VoiceLink {
  /** The session Aiur minted for the current hold, or null before the reply. */
  let session: string | null = null;
  /**
   * Frames captured before the reply landed.
   *
   * `voice_start`'s session id arrives in a `phx_reply`, which is at least one
   * round trip after capture begins — and capture begins deliberately early so
   * the recorder does not swallow the operator's first word. Dropping those
   * frames would clip exactly the syllable the early start exists to protect,
   * so they are held and flushed once the id is known.
   */
  let queued: string[] = [];
  /** True when the hold ended before the reply arrived. */
  let stopWanted = false;
  /** True between `start()` and the end of the hold. */
  let open = false;

  const reset = (): void => {
    session = null;
    queued = [];
    stopWanted = false;
    open = false;
  };

  return {
    port: {
      start(): void {
        reset();
        open = true;
        options.channel()?.voiceStart();
      },
      audio(base64: string): void {
        if (!open) return;
        if (session === null) {
          queued.push(base64);
          return;
        }
        options.channel()?.voiceAudio(session, base64);
      },
      stop(): void {
        if (!open) return;
        if (session === null) {
          // The reply is still in flight. Remember the intent rather than
          // dropping it: `started` performs the stop the moment it can.
          stopWanted = true;
          return;
        }
        options.channel()?.voiceStop(session);
        reset();
      },
    },

    started(id: string | null, reason: string | null): void {
      if (!open) {
        // A reply for a hold that has already been abandoned. Closing the
        // server's session is still owed, or Aiur keeps a provider socket open
        // for a hold that ended.
        if (id !== null) options.channel()?.voiceStop(id);
        return;
      }
      if (id === null) {
        const failure = reason ?? VOICE_START_REFUSED;
        reset();
        options.relay()?.fail(failure);
        return;
      }
      session = id;
      const channel = options.channel();
      for (const frame of queued) channel?.voiceAudio(id, frame);
      queued = [];
      if (stopWanted) {
        channel?.voiceStop(id);
        reset();
      }
    },

    transcript(id: string, event: TranscriptEvent): void {
      // A late frame from a previous hold must not land in the buffer of the
      // current one, so anything not naming the open session is dropped.
      if (id !== session) return;
      options.relay()?.deliver(event);
    },

    failed(id: string, reason: string): void {
      if (id !== session) return;
      reset();
      options.relay()?.fail(reason);
    },

    closed(id: string): void {
      if (id !== session) return;
      reset();
      options.relay()?.finish();
    },

    drop(reason: string): void {
      if (!open) return;
      reset();
      options.relay()?.fail(reason);
    },
  };
}

/**
 * Minimum interval between voice-driven repaints, in milliseconds.
 *
 * The voice session's `onUpdate` fires once per 20 ms capture chunk — 50 Hz.
 * Rasterizing an 800x100 panel and pushing it over USB at that rate would spend
 * the whole event loop on frames nobody can see: 10 Hz is already past the rate
 * at which a moving trace reads as continuous, and it leaves the USB poll free
 * to drain input. The trace itself does not lose resolution, because every
 * chunk is still folded into the waveform — only the *painting* is coalesced.
 */
export const VOICE_REPAINT_INTERVAL_MS = 100;

export interface RepaintCoalescerOptions {
  readonly repaint: () => void;
  readonly now: () => number;
  readonly setTimer: (fn: () => void, ms: number) => void;
  /** Injected so no test depends on wall-clock time. */
  readonly intervalMs?: number;
}

export interface RepaintCoalescer {
  /** Ask for a repaint; at most one lands per interval. */
  request(): void;
}

export function createRepaintCoalescer(options: RepaintCoalescerOptions): RepaintCoalescer {
  const intervalMs = options.intervalMs ?? VOICE_REPAINT_INTERVAL_MS;
  /** When the last repaint went out; -Infinity so the first request is immediate. */
  let last = Number.NEGATIVE_INFINITY;
  let scheduled = false;

  const fire = (): void => {
    last = options.now();
    options.repaint();
  };

  return {
    request(): void {
      // A request already waiting on the timer covers this one: the timer
      // repaints from whatever the state is when it fires, which is newer than
      // anything a second scheduled callback could show.
      if (scheduled) return;
      const elapsed = options.now() - last;
      if (elapsed >= intervalMs) {
        fire();
        return;
      }
      scheduled = true;
      options.setTimer(() => {
        scheduled = false;
        fire();
      }, intervalMs - elapsed);
    },
  };
}

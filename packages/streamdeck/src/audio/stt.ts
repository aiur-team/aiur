/**
 * Provider-agnostic speech-to-text contract.
 *
 * Nothing below names ElevenLabs, and nothing imports from the Stream Deck
 * sidecar. This is the seam the voice stack is meant to be extracted along:
 * a future package would take `src/audio/**` wholesale, and the only thing the
 * sidecar keeps is a call to `createVoiceSession` with a transcriber it chose.
 */

/** Minimal websocket shape, redeclared here so the audio stack owns no sidecar types. */
export interface SocketLike {
  send(data: string): void;
  close(): void;
  onopen: (() => void) | null;
  onmessage: ((event: { data: string }) => void) | null;
  onerror: ((error: unknown) => void) | null;
  onclose: (() => void) | null;
}

export type SocketFactory = (url: string, headers: Readonly<Record<string, string>>) => SocketLike;

/**
 * A transcript update.
 *
 * `partial` text is revised in place as the model hears more, so a consumer
 * must replace rather than append it. `final` text is settled and is what the
 * accumulating buffer keeps.
 */
export interface TranscriptEvent {
  readonly kind: "partial" | "final";
  readonly text: string;
}

export interface TranscriberHandlers {
  /** Called for every partial and final update. */
  onTranscript(event: TranscriptEvent): void;
  /**
   * Called when the provider fails mid-stream. The session is finished at this
   * point; the operator sees the reason rather than a silently dead mic.
   */
  onError(reason: string): void;
}

/** One open streaming transcription. Audio is pushed in as it is captured. */
export interface TranscriberSession {
  /** Pushes one chunk of raw PCM in the format the transcriber advertised. */
  push(pcm: Uint8Array): void;
  /** Stops sending and releases the connection. Safe to call twice. */
  close(): void;
}

export interface Transcriber {
  /** False when the integration is not configured; the UI degrades on this. */
  readonly available: boolean;
  /**
   * Operator-facing explanation when `available` is false. Always non-null in
   * that case so the deck can say *why* rather than showing silent failure.
   */
  readonly unavailableReason: string | null;
  open(handlers: TranscriberHandlers): TranscriberSession;
}

/**
 * The transcriber used when no API key is configured.
 *
 * It never opens a socket, so no audio leaves the machine. Capture, the
 * waveform and the decibel bar all still work — only transcription is absent,
 * and the reason is carried where the UI can print it.
 */
export function createUnavailableTranscriber(reason: string): Transcriber {
  return {
    available: false,
    unavailableReason: reason,
    open(handlers: TranscriberHandlers): TranscriberSession {
      handlers.onError(reason);
      return { push: () => {}, close: () => {} };
    },
  };
}

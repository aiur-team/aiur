/**
 * Public surface of the voice stack.
 *
 * This is the extraction boundary. Everything under `src/audio/` depends only
 * on itself, on the two-function `SystemPort`, and on a websocket factory —
 * never on Stream Deck modules, the Phoenix channel, the rasterizer or any
 * Aiur concept. Consumers import from here and nowhere deeper, so moving the
 * directory into its own package is a `git mv` plus a change of import
 * specifier at the handful of call sites.
 *
 * The one Node-coupled file is `node-system.ts`, which is the adapter a host
 * supplies; a browser or test host supplies its own and the core is unchanged.
 */

import { createElevenLabsTranscriber } from "./elevenlabs.js";
import { createUnavailableTranscriber, type SocketFactory, type Transcriber } from "./stt.js";

export { DEFAULT_PCM_FORMAT, FLOOR_DBFS, dbfsToFill, decodePcm16, measure, peak, rms, toDbfs } from "./pcm.js";
export type { LevelReading, PcmFormat } from "./pcm.js";

export { createWaveformScroll } from "./waveform.js";
export type { WaveformColumn, WaveformScroll } from "./waveform.js";

export { createTranscriptBuffer } from "./buffer.js";
export type { TranscriptBuffer } from "./buffer.js";

export { createUnavailableTranscriber } from "./stt.js";
export type {
  SocketFactory,
  SocketLike,
  Transcriber,
  TranscriberHandlers,
  TranscriberSession,
  TranscriptEvent,
} from "./stt.js";

export { ELEVENLABS_REALTIME_MODEL, ELEVENLABS_REALTIME_URL, createElevenLabsTranscriber } from "./elevenlabs.js";
export type { ElevenLabsTranscriberOptions } from "./elevenlabs.js";

export { PACTL, PW_DUMP, listMicrophones } from "./devices.js";
export type { AudioDevice } from "./devices.js";

export { CAPTURE_LATENCY_MS, FIRST_BYTE_TIMEOUT_MS, PAREC, captureArgs, startCapture } from "./capture.js";
export type { Capture, CaptureHandlers, CaptureOptions, Scheduler } from "./capture.js";

export { TARGET_FRAME_BYTES, createChunkAggregator } from "./aggregate.js";
export type { ChunkAggregator } from "./aggregate.js";

export { createMicPreferences } from "./preferences.js";
export type { MicPreferences, PreferenceStore } from "./preferences.js";

export { createVoiceSession } from "./session.js";
export type { VoiceSession, VoiceSessionOptions } from "./session.js";

export type { SpawnedProcess, SystemPort } from "./system.js";

export { createNodeSystem, RUN_TIMEOUT_MS } from "./node-system.js";
export { createNodeSocket } from "./node-socket.js";

/** Shown on the deck when the integration is not configured. */
export const NO_API_KEY_REASON = "No ElevenLabs API key - transcription is off";

export interface TranscriberSelection {
  readonly apiKey: string | null | undefined;
  readonly socket: SocketFactory;
  readonly languageCode?: string;
  readonly sampleRate?: number;
}

/**
 * Builds the transcriber for a given configuration.
 *
 * An absent key yields an unavailable transcriber carrying a printable reason
 * — not an exception and not a silent no-op. The caller shows the reason,
 * while capture, the waveform and the decibel bar keep working, because
 * without a key there is nowhere for audio to be sent.
 */
export function selectTranscriber(options: TranscriberSelection): Transcriber {
  const apiKey = options.apiKey ?? "";
  if (apiKey === "") return createUnavailableTranscriber(NO_API_KEY_REASON);

  return createElevenLabsTranscriber({
    apiKey,
    socket: options.socket,
    ...(options.languageCode === undefined ? {} : { languageCode: options.languageCode }),
    ...(options.sampleRate === undefined ? {} : { sampleRate: options.sampleRate }),
  });
}

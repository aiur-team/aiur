/**
 * Public surface of the voice stack.
 *
 * This is the extraction boundary. Everything under `src/audio/` depends only
 * on itself and on three injected ports: the two-function `SystemPort` for
 * spawning the recorder, a `VoiceRelayPort` for reaching Aiur, and a
 * `PreferenceStore` for the remembered microphone. It never depends on Stream
 * Deck modules, the Phoenix channel, the rasterizer or any Aiur concept.
 * Consumers import from here and nowhere deeper, so moving the directory into
 * its own package is a `git mv` plus a change of import specifier at the
 * handful of call sites.
 *
 * It contains **no provider credential at all**. Aiur performs the ElevenLabs
 * call; the sidecar only streams audio to it, so there is nothing here for a
 * log line, an error message or a crash dump to leak.
 *
 * The Node-coupled files are `node-system.ts` and `node-preferences.ts`, which
 * are the adapters a host supplies; a browser or test host supplies its own and
 * the core is unchanged.
 */

export { DEFAULT_PCM_FORMAT, FLOOR_DBFS, dbfsToFill, decodePcm16, measure, peak, rms, toDbfs } from "./pcm.js";
export type { LevelReading, PcmFormat } from "./pcm.js";

export { createWaveformScroll } from "./waveform.js";
export type { WaveformColumn, WaveformScroll } from "./waveform.js";

export { createTranscriptBuffer } from "./buffer.js";
export type { TranscriptBuffer } from "./buffer.js";

export { createUnavailableTranscriber } from "./stt.js";
export type { Transcriber, TranscriberHandlers, TranscriberSession, TranscriptEvent } from "./stt.js";

export { createRelayTranscriber } from "./relay.js";
export type { RelayTranscriber, RelayTranscriberOptions, VoiceRelayPort } from "./relay.js";

export { PACTL, PW_DUMP, listMicrophones } from "./devices.js";
export type { AudioDevice } from "./devices.js";

export { CAPTURE_LATENCY_MS, FIRST_BYTE_TIMEOUT_MS, PAREC, captureArgs, startCapture } from "./capture.js";
export type { Capture, CaptureHandlers, CaptureOptions, Scheduler } from "./capture.js";

export { TARGET_FRAME_BYTES, createChunkAggregator } from "./aggregate.js";
export type { ChunkAggregator } from "./aggregate.js";

export { createMicPreferences } from "./preferences.js";
export type { MicPreferences, PreferenceStore } from "./preferences.js";

export { createFilePreferenceStore } from "./node-preferences.js";
export type { FileSystemPort } from "./node-preferences.js";

export { createVoiceSession } from "./session.js";
export type { VoiceSession, VoiceSessionOptions } from "./session.js";

export type { SpawnedProcess, SystemPort } from "./system.js";

export { createNodeSystem, RUN_TIMEOUT_MS } from "./node-system.js";

/**
 * Shown on the deck when Aiur reports voice is not configured.
 *
 * The key lives in Aiur, so the sidecar cannot tell whether one is configured
 * until `voice_start` is refused. The reason therefore names *Aiur* as the
 * place to fix it — an operator told only "no API key" would go looking in the
 * sidecar's config, where by design there is nothing to find.
 */
export const VOICE_UNCONFIGURED_REASON = "Aiur has no ElevenLabs API key - transcription is off";

/**
 * The voice session: one object the UI drives with press and release.
 *
 * It owns the wiring between capture, the level meter, the waveform, the
 * transcriber and the accumulating buffer, and it exposes only what a renderer
 * needs to paint. The renderer never sees a process, a socket or a byte.
 *
 * There is no timer here. Everything advances on captured audio or on a
 * provider frame, so tests drive a whole session deterministically by handing
 * chunks to a fake capture — no sleeps, no fake clocks, nothing that can flake.
 */

import { type LevelReading, measure, decodePcm16, DEFAULT_PCM_FORMAT, type PcmFormat } from "./pcm.js";
import { createChunkAggregator } from "./aggregate.js";
import { createTranscriptBuffer, type TranscriptBuffer } from "./buffer.js";
import { createWaveformScroll, type WaveformColumn, type WaveformScroll } from "./waveform.js";
import { startCapture, type Capture, type CaptureOptions } from "./capture.js";
import type { SystemPort } from "./system.js";
import type { Transcriber, TranscriberSession } from "./stt.js";

const SILENT_LEVEL: LevelReading = Object.freeze({ rms: 0, peak: 0, dbfs: -60, fill: 0 });

export interface VoiceSessionOptions {
  readonly system: SystemPort;
  readonly transcriber: Transcriber;
  /** Chosen microphone; null records from the server default. */
  readonly deviceId: string | null;
  /** Columns the waveform panel can draw. */
  readonly waveformWidth: number;
  readonly format?: PcmFormat;
  /** Called whenever the level, waveform or text changed and a repaint is due. */
  readonly onUpdate: () => void;
  /** Called with an operator-facing reason when capture or transcription fails. */
  readonly onError: (reason: string) => void;
  /** Test seam for capture; defaults to the real recorder. */
  readonly capture?: (options: CaptureOptions, handlers: { onChunk(pcm: Uint8Array): void; onError(reason: string): void }) => Capture;
}

export interface VoiceSession {
  /** True while the mic key is held. */
  readonly holding: boolean;
  /** False when no API key is configured; the meters still work. */
  readonly transcriptionAvailable: boolean;
  /** Why transcription is unavailable, for the operator to read. */
  readonly unavailableReason: string | null;
  /** Begins capture. Idempotent, so a repeated key-down cannot open two. */
  hold(): void;
  /** Ends capture, keeping settled text in the buffer. Idempotent. */
  release(): void;
  level(): LevelReading;
  waveform(): readonly WaveformColumn[];
  /** Settled text plus the live partial, for the bottom panel. */
  text(): string;
  /** Settled text only, for delivery to the agent. */
  message(): string;
  hasMessage(): boolean;
  /** Discards the buffer. Backs Cancel, and follows a successful Send. */
  clear(): void;
  /** Releases capture and the provider connection. */
  dispose(): void;
}

export function createVoiceSession(options: VoiceSessionOptions): VoiceSession {
  const format = options.format ?? DEFAULT_PCM_FORMAT;
  const startCaptureFn = options.capture ?? startCapture;
  const buffer: TranscriptBuffer = createTranscriptBuffer();
  // One column per 50 ms of audio keeps a full panel showing a couple of
  // seconds of speech, which is the span that reads as a waveform rather than
  // as noise.
  const waveform: WaveformScroll = createWaveformScroll(
    options.waveformWidth,
    Math.max(1, Math.round(format.sampleRate / 20)),
  );

  let capture: Capture | null = null;
  let transcription: TranscriberSession | null = null;
  let level: LevelReading = SILENT_LEVEL;

  // Capture runs at a 20 ms latency so the recorder does not swallow the first
  // word, but the transcriber wants frames an order of magnitude larger. The
  // meters therefore consume every small chunk directly, while the transcriber
  // sees them re-grouped.
  //
  // Declared above `stopCapture`, which closes over it: a hoisted function
  // referencing a `const` below it works only while nothing calls it during
  // construction, and would become a temporal-dead-zone ReferenceError the
  // moment something did.
  const aggregator = createChunkAggregator((frame) => transcription?.push(frame));

  const fail = (reason: string): void => {
    stopCapture();
    options.onError(reason);
  };

  function stopCapture(): void {
    capture?.stop();
    capture = null;
    // The tail of an utterance is almost always a partial frame; sending it
    // before the socket closes is what stops the last word being clipped.
    aggregator.flush();
    transcription?.close();
    transcription = null;
    level = SILENT_LEVEL;
    buffer.dropPartial();
  }

  const onChunk = (pcm: Uint8Array): void => {
    const samples = decodePcm16(pcm);
    level = measure(samples);
    waveform.push(samples);
    // No key means no socket was opened, so nothing leaves the machine: the
    // meters above run on the same chunk either way.
    aggregator.push(pcm);
    options.onUpdate();
  };

  return {
    get holding(): boolean {
      return capture !== null;
    },
    get transcriptionAvailable(): boolean {
      return options.transcriber.available;
    },
    get unavailableReason(): string | null {
      return options.transcriber.unavailableReason;
    },
    hold(): void {
      if (capture !== null) return;
      waveform.reset();
      aggregator.reset();
      if (options.transcriber.available) {
        transcription = options.transcriber.open({
          onTranscript: (event) => {
            buffer.apply(event);
            options.onUpdate();
          },
          onError: fail,
        });
      }
      capture = startCaptureFn(
        { system: options.system, deviceId: options.deviceId, format },
        { onChunk, onError: fail },
      );
    },
    release(): void {
      if (capture === null) return;
      stopCapture();
      options.onUpdate();
    },
    level: () => level,
    waveform: () => waveform.columns(),
    text: () => buffer.display(),
    message: () => buffer.committed(),
    hasMessage: () => !buffer.isEmpty(),
    clear(): void {
      buffer.clear();
      options.onUpdate();
    },
    dispose(): void {
      stopCapture();
    },
  };
}

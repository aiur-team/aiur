/**
 * Chunked microphone capture.
 *
 * `parec` writes raw s16le to stdout, so a capture is one long-lived process
 * whose stdout is consumed as it arrives — semi-real-time by construction,
 * with no polling and no clock of our own. Measured on a Yeti X: exactly
 * 32 000 B/s at 16 kHz mono, matching the format we ask for.
 *
 * The recorder is asked for the same 16 kHz mono the transcriber wants, so
 * nothing in this codebase resamples.
 *
 * Three of the constants below are not preferences; each encodes an observed
 * failure on this hardware and is commented where it is set.
 */

import { DEFAULT_PCM_FORMAT, type PcmFormat } from "./pcm.js";
import type { SpawnedProcess, SystemPort } from "./system.js";

export const PAREC = "parec";

/**
 * Mandatory, not a tuning knob. Without an explicit `--latency-msec`, `parec`
 * emits nothing at all for roughly the first second and then starts mid-word —
 * for push-to-talk that is the difference between working and eating the first
 * word of every utterance. 20 ms was measured to deliver the full stream from
 * the start. Chunks this small are re-grouped before transcription; see
 * `aggregate.ts`.
 */
export const CAPTURE_LATENCY_MS = 20;

/**
 * A recorder given a device name that does not exist hangs forever and writes
 * nothing to stderr, so silence has to be turned into an error by a deadline.
 * Callers validate the device against the enumeration first; this is the
 * backstop for a microphone unplugged between the two.
 */
export const FIRST_BYTE_TIMEOUT_MS = 750;

/** Injectable one-shot timer, so the deadline is testable without waiting. */
export type Scheduler = (callback: () => void, delayMs: number) => { cancel(): void };

const defaultScheduler: Scheduler = (callback, delayMs) => {
  const handle = setTimeout(callback, delayMs);
  handle.unref();
  return { cancel: () => clearTimeout(handle) };
};

export interface CaptureHandlers {
  onChunk(pcm: Uint8Array): void;
  /** Fires when capture fails; never on a requested stop. */
  onError(reason: string): void;
}

export interface Capture {
  stop(): void;
}

export interface CaptureOptions {
  readonly system: SystemPort;
  /** Source name; null uses the server default. */
  readonly deviceId: string | null;
  readonly format?: PcmFormat;
  readonly latencyMs?: number;
  readonly firstByteTimeoutMs?: number;
  readonly scheduler?: Scheduler;
}

/** Builds the recorder argv. Exported so a test can assert it exactly. */
export function captureArgs(
  deviceId: string | null,
  format: PcmFormat,
  latencyMs: number,
): string[] {
  const args = [
    "--raw",
    `--format=s${format.bitDepth}le`,
    `--rate=${format.sampleRate}`,
    `--channels=${format.channels}`,
    `--latency-msec=${latencyMs}`,
  ];
  if (deviceId !== null) args.push(`--device=${deviceId}`);
  return args;
}

export function startCapture(options: CaptureOptions, handlers: CaptureHandlers): Capture {
  const format = options.format ?? DEFAULT_PCM_FORMAT;
  const latencyMs = options.latencyMs ?? CAPTURE_LATENCY_MS;
  const scheduler = options.scheduler ?? defaultScheduler;
  const args = captureArgs(options.deviceId, format, latencyMs);

  let stopped = false;
  let heardAudio = false;
  const process: SpawnedProcess = options.system.spawn(PAREC, args);

  const deadline = scheduler(() => {
    if (stopped || heardAudio) return;
    stopped = true;
    process.kill();
    handlers.onError("Microphone produced no audio - check the selected device");
  }, options.firstByteTimeoutMs ?? FIRST_BYTE_TIMEOUT_MS);

  process.onData((chunk: Uint8Array): void => {
    if (stopped) return;
    heardAudio = true;
    deadline.cancel();
    handlers.onChunk(chunk);
  });

  process.onExit((code: number | null): void => {
    // A requested stop kills the process, so a non-zero code afterwards is
    // expected and must not be reported as a microphone failure.
    if (stopped) return;
    stopped = true;
    deadline.cancel();
    handlers.onError(
      code === 0
        ? "Microphone capture ended unexpectedly"
        : `Microphone capture failed (exit ${String(code)})`,
    );
  });

  return {
    stop(): void {
      if (stopped) return;
      stopped = true;
      deadline.cancel();
      process.kill();
    },
  };
}

/**
 * Signed 16-bit PCM decoding and level measurement.
 *
 * This is the numeric floor of the voice stack and deliberately depends on
 * nothing — no Node built-ins, no Stream Deck types, no clock. Every function
 * is pure so the waveform and decibel bar can be tested from fixed byte
 * vectors instead of a live microphone, which is what keeps the audio suite
 * out of the flaky-timing class of tests tracked in #1920.
 */

/** Layout of a raw capture stream. Only s16le is produced by our capture CLI. */
export interface PcmFormat {
  readonly sampleRate: number;
  readonly channels: number;
  readonly bitDepth: 16;
}

/**
 * 16 kHz mono is the lowest rate that speech-to-text accepts without
 * resampling, which keeps both the upload size and the CPU cost down on the
 * machine that is also driving the deck.
 */
export const DEFAULT_PCM_FORMAT: PcmFormat = Object.freeze({
  sampleRate: 16_000,
  channels: 1,
  bitDepth: 16,
});

/**
 * Quietest level the meter reports. Digital silence is negatively infinite
 * dBFS, which cannot be drawn, so the scale is clamped to a floor that still
 * leaves room for genuine room tone above it.
 */
export const FLOOR_DBFS = -60;

const INT16_SCALE = 32_768;

/**
 * Decodes s16le bytes into samples normalized to -1..1.
 *
 * A trailing odd byte is dropped rather than throwing: capture chunks arrive
 * on pipe boundaries that do not have to respect frame alignment, and losing
 * half a sample is not worth failing a whole chunk over.
 */
export function decodePcm16(bytes: Uint8Array): Float32Array {
  const frames = Math.floor(bytes.length / 2);
  const samples = new Float32Array(frames);
  for (let i = 0; i < frames; i += 1) {
    const low = bytes[i * 2] as number;
    const high = bytes[i * 2 + 1] as number;
    // Reconstitute the little-endian pair, then sign-extend the 16-bit value.
    const unsigned = low | (high << 8);
    const signed = unsigned >= INT16_SCALE ? unsigned - 65_536 : unsigned;
    samples[i] = signed / INT16_SCALE;
  }
  return samples;
}

/** Root-mean-square amplitude, 0..1. Empty input is silence, not NaN. */
export function rms(samples: Float32Array): number {
  if (samples.length === 0) return 0;
  let sum = 0;
  for (const sample of samples) sum += sample * sample;
  return Math.sqrt(sum / samples.length);
}

/** Largest absolute amplitude in the window, 0..1. */
export function peak(samples: Float32Array): number {
  let highest = 0;
  for (const sample of samples) {
    const magnitude = Math.abs(sample);
    if (magnitude > highest) highest = magnitude;
  }
  return highest;
}

/** Converts a 0..1 amplitude to dBFS, clamped to the drawable floor. */
export function toDbfs(amplitude: number): number {
  if (amplitude <= 0) return FLOOR_DBFS;
  const db = 20 * Math.log10(amplitude);
  return db < FLOOR_DBFS ? FLOOR_DBFS : Math.min(db, 0);
}

/**
 * Maps dBFS onto the 0..1 fill of the vertical level bar.
 *
 * The mapping is linear in decibels rather than in amplitude so that normal
 * speech sits around two thirds of the bar; a linear-amplitude bar spends
 * almost its whole travel in the top few decibels and reads as broken.
 */
export function dbfsToFill(db: number): number {
  const clamped = Math.min(0, Math.max(FLOOR_DBFS, db));
  return (clamped - FLOOR_DBFS) / -FLOOR_DBFS;
}

/** Convenience: the level of one chunk, as both a decibel and a bar fill. */
export interface LevelReading {
  readonly rms: number;
  readonly peak: number;
  readonly dbfs: number;
  readonly fill: number;
}

export function measure(samples: Float32Array): LevelReading {
  const amplitude = rms(samples);
  const dbfs = toDbfs(amplitude);
  return { rms: amplitude, peak: peak(samples), dbfs, fill: dbfsToFill(dbfs) };
}

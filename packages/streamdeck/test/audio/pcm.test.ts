import { describe, expect, it } from "vitest";
import {
  DEFAULT_PCM_FORMAT,
  FLOOR_DBFS,
  dbfsToFill,
  decodePcm16,
  measure,
  peak,
  rms,
  toDbfs,
} from "../../src/audio/pcm.js";

/** Encodes signed 16-bit values little-endian, the layout capture emits. */
const s16le = (values: readonly number[]): Uint8Array => {
  const bytes = new Uint8Array(values.length * 2);
  values.forEach((value, index) => {
    const unsigned = value < 0 ? value + 65_536 : value;
    bytes[index * 2] = unsigned & 0xff;
    bytes[index * 2 + 1] = (unsigned >> 8) & 0xff;
  });
  return bytes;
};

describe("PCM decoding", () => {
  it("declares 16 kHz mono, the rate speech-to-text takes without resampling", () => {
    expect(DEFAULT_PCM_FORMAT).toEqual({ sampleRate: 16_000, channels: 1, bitDepth: 16 });
  });

  it("normalizes positive and negative samples to -1..1", () => {
    const samples = decodePcm16(s16le([0, 16_384, -16_384, -32_768, 32_767]));
    expect(Array.from(samples)).toEqual([0, 0.5, -0.5, -1, 32_767 / 32_768]);
  });

  it("drops a trailing odd byte instead of failing the chunk", () => {
    // Capture chunks land on pipe boundaries that need not be frame aligned.
    const bytes = new Uint8Array([0x00, 0x40, 0x7f]);
    expect(Array.from(decodePcm16(bytes))).toEqual([0.5]);
  });

  it("returns an empty window for an empty buffer", () => {
    expect(decodePcm16(new Uint8Array(0)).length).toBe(0);
  });
});

describe("level measurement", () => {
  it("reports silence rather than NaN for an empty window", () => {
    expect(rms(new Float32Array(0))).toBe(0);
    expect(peak(new Float32Array(0))).toBe(0);
  });

  it("computes root-mean-square amplitude", () => {
    expect(rms(new Float32Array([0.5, -0.5]))).toBeCloseTo(0.5, 10);
  });

  it("takes the largest magnitude regardless of sign", () => {
    // Binary fractions only: Float32Array would round 0.9 to 0.8999999761581421
    // and turn an exact assertion into a false failure.
    expect(peak(new Float32Array([0.125, -0.75, 0.5]))).toBe(0.75);
  });

  it("floors digital silence at the drawable minimum", () => {
    expect(toDbfs(0)).toBe(FLOOR_DBFS);
    expect(toDbfs(-1)).toBe(FLOOR_DBFS);
  });

  it("clamps levels quieter than the floor up to it", () => {
    expect(toDbfs(0.0000001)).toBe(FLOOR_DBFS);
  });

  it("caps overdriven input at full scale", () => {
    // Above-unity amplitude would otherwise report positive dBFS and overflow
    // the bar, so the scale tops out at 0.
    expect(toDbfs(4)).toBe(0);
  });

  it("maps half scale to roughly -6 dBFS", () => {
    expect(toDbfs(0.5)).toBeCloseTo(-6.02, 2);
  });
});

describe("bar fill", () => {
  it("empties at the floor and fills at full scale", () => {
    expect(dbfsToFill(FLOOR_DBFS)).toBe(0);
    expect(dbfsToFill(0)).toBe(1);
  });

  it("clamps out-of-range decibels into the bar", () => {
    expect(dbfsToFill(FLOOR_DBFS - 40)).toBe(0);
    expect(dbfsToFill(12)).toBe(1);
  });

  it("is linear in decibels so speech sits mid-bar", () => {
    expect(dbfsToFill(FLOOR_DBFS / 2)).toBeCloseTo(0.5, 10);
  });
});

describe("measure", () => {
  it("bundles amplitude, peak, decibels and fill for one chunk", () => {
    const reading = measure(decodePcm16(s16le([16_384, -16_384])));
    expect(reading.rms).toBeCloseTo(0.5, 10);
    expect(reading.peak).toBe(0.5);
    expect(reading.dbfs).toBeCloseTo(-6.02, 2);
    expect(reading.fill).toBeCloseTo(dbfsToFill(reading.dbfs), 10);
  });
});

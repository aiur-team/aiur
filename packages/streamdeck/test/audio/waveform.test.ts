import { describe, expect, it } from "vitest";
import { createWaveformScroll } from "../../src/audio/waveform.js";

describe("waveform scroll", () => {
  it("rejects a non-drawable width", () => {
    expect(() => createWaveformScroll(0, 4)).toThrow(/width must be positive/);
  });

  it("rejects a column that condenses no samples", () => {
    expect(() => createWaveformScroll(4, 0)).toThrow(/samplesPerColumn must be positive/);
  });

  it("starts full width at the baseline so the panel never grows in", () => {
    const scroll = createWaveformScroll(3, 2);
    expect(scroll.columns()).toEqual([
      { min: 0, max: 0 },
      { min: 0, max: 0 },
      { min: 0, max: 0 },
    ]);
  });

  it("condenses each group of samples into one min/max column", () => {
    // Binary fractions throughout: Float32Array rounds a literal like 0.2 to
    // 0.20000000298023224, so exact equality on a decimal would fail for a
    // reason that has nothing to do with the reduction.
    const scroll = createWaveformScroll(3, 2);
    scroll.push(new Float32Array([0.25, 0.75]));
    expect(scroll.columns()[2]).toEqual({ min: 0.25, max: 0.75 });
  });

  it("keeps peaks and valleys rather than rectifying to a magnitude", () => {
    const scroll = createWaveformScroll(2, 3);
    scroll.push(new Float32Array([0.5, -0.75, 0.25]));
    expect(scroll.columns()[1]).toEqual({ min: -0.75, max: 0.5 });
  });

  it("holds a partial column back until it fills", () => {
    const scroll = createWaveformScroll(2, 4);
    scroll.push(new Float32Array([0.875, -0.875]));
    expect(scroll.columns()).toEqual([
      { min: 0, max: 0 },
      { min: 0, max: 0 },
    ]);
    scroll.push(new Float32Array([0.125, 0.125]));
    expect(scroll.columns()[1]).toEqual({ min: -0.875, max: 0.875 });
  });

  it("puts the newest audio on the right and drops the oldest column", () => {
    const scroll = createWaveformScroll(2, 1);
    scroll.push(new Float32Array([0.125, 0.25, 0.375]));
    expect(scroll.columns()).toEqual([
      { min: 0.25, max: 0.25 },
      { min: 0.375, max: 0.375 },
    ]);
  });

  it("clears history when capture restarts on another device", () => {
    const scroll = createWaveformScroll(2, 2);
    scroll.push(new Float32Array([0.375, 0.625, 0.5]));
    scroll.reset();
    expect(scroll.columns()).toEqual([
      { min: 0, max: 0 },
      { min: 0, max: 0 },
    ]);
    // The half-finished column was discarded too, not carried into the next one.
    scroll.push(new Float32Array([0.125, 0.25]));
    expect(scroll.columns()[1]).toEqual({ min: 0.125, max: 0.25 });
  });
});

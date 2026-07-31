import { describe, expect, it } from "vitest";

import { formatEta, summaryModel } from "../../src/touchStrip/summarySegment.js";

describe("summaryModel", () => {
  it("carries clamped live and remaining counts", () => {
    const model = summaryModel(3, 5);
    expect(model.live).toBe(3);
    expect(model.remaining).toBe(5);
    expect(model.build).toBeNull();
  });

  it("floors and clamps negative or fractional counts to non-negative ints", () => {
    const model = summaryModel(-2, 4.7);
    expect(model.live).toBe(0);
    expect(model.remaining).toBe(4);
  });

  it("treats non-finite counts as zero", () => {
    const model = summaryModel(Number.NaN, Number.POSITIVE_INFINITY);
    expect(model.live).toBe(0);
    expect(model.remaining).toBe(0);
  });

  it("treats a non-finite completed count as zero", () => {
    const model = summaryModel(0, 0, { completed: Number.NaN, total: 4 });
    expect(model.build!.completed).toBe(0);
    expect(model.build!.fraction).toBe(0);
  });

  it("builds a mini-bar fraction from completed/total", () => {
    const model = summaryModel(1, 2, { completed: 3, total: 12, etaSeconds: 130 });
    expect(model.build).not.toBeNull();
    expect(model.build!.fraction).toBeCloseTo(0.25);
    expect(model.build!.completed).toBe(3);
    expect(model.build!.total).toBe(12);
    expect(model.build!.etaLabel).toBe("3m");
  });

  it("reports build: null when there is no total — never a fabricated 0%", () => {
    expect(summaryModel(1, 1, { completed: 0, total: 0 }).build).toBeNull();
    expect(summaryModel(1, 1, null).build).toBeNull();
    expect(summaryModel(1, 1).build).toBeNull();
  });

  it("clamps completed to total so the bar never exceeds 100%", () => {
    const model = summaryModel(0, 0, { completed: 99, total: 10 });
    expect(model.build!.completed).toBe(10);
    expect(model.build!.fraction).toBe(1);
  });

  it("omits the ETA label when no ETA was projected", () => {
    const model = summaryModel(0, 0, { completed: 1, total: 2 });
    expect(model.build!.etaLabel).toBeNull();
  });
});

describe("formatEta", () => {
  it("rounds sub-minute up to 1m so imminent finishes never read 0m", () => {
    expect(formatEta(5)).toBe("1m");
    expect(formatEta(0)).toBe("1m");
  });

  it("formats minutes and hours compactly", () => {
    expect(formatEta(120)).toBe("2m");
    expect(formatEta(3600)).toBe("1h");
    expect(formatEta(3900)).toBe("1h 5m");
  });

  it("returns null for null or negative input", () => {
    expect(formatEta(null)).toBeNull();
    expect(formatEta(undefined)).toBeNull();
    expect(formatEta(-1)).toBeNull();
  });
});

import { describe, expect, it } from "vitest";

import { pagerModel } from "../../src/touchStrip/pagerSegment.js";

describe("pagerModel", () => {
  it("computes window count from real agent count and per-window capacity", () => {
    const model = pagerModel(9, 4, 0);
    expect(model.windowCount).toBe(3); // ceil(9 / 4)
    expect(model.dots).toEqual([true, false, false]);
    expect(model.hasMultiple).toBe(true);
  });

  it("fills the dot for the focused window", () => {
    const model = pagerModel(9, 4, 1);
    expect(model.currentWindow).toBe(1);
    expect(model.dots).toEqual([false, true, false]);
  });

  it("clamps an out-of-range current window into the last dot", () => {
    const model = pagerModel(9, 4, 99);
    expect(model.currentWindow).toBe(2);
    expect(model.dots).toEqual([false, false, true]);
  });

  it("keeps exactly one stable window when there are no agents", () => {
    const model = pagerModel(0, 4, 0);
    expect(model.windowCount).toBe(1);
    expect(model.dots).toEqual([true]);
    expect(model.hasMultiple).toBe(false);
  });

  it("treats a full single window as not-multiple", () => {
    const model = pagerModel(4, 4, 0);
    expect(model.windowCount).toBe(1);
    expect(model.hasMultiple).toBe(false);
  });

  it("guards against a non-positive per-window capacity", () => {
    const model = pagerModel(3, 0, 0);
    expect(model.windowCount).toBe(3); // capacity coerced to 1
    expect(model.dots).toEqual([true, false, false]);
  });

  it("coerces fractional / invalid inputs to sane integers", () => {
    const model = pagerModel(5.9, 2.4, -3);
    expect(model.windowCount).toBe(3); // ceil(5 / 2)
    expect(model.currentWindow).toBe(0);
  });
});

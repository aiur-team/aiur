import { describe, expect, it } from "vitest";

import {
  DEFAULT_JPEG_QUALITY,
  MAX_JPEG_QUALITY,
  MIN_JPEG_QUALITY,
  resolveJpegQuality,
} from "../../src/keys/quality.js";

describe("resolveJpegQuality", () => {
  it("defaults to the justified 90 when unset", () => {
    expect(DEFAULT_JPEG_QUALITY).toBe(90);
    expect(resolveJpegQuality()).toBe(90);
  });

  it("accepts in-range integers including the bounds", () => {
    expect(resolveJpegQuality(MIN_JPEG_QUALITY)).toBe(1);
    expect(resolveJpegQuality(MAX_JPEG_QUALITY)).toBe(100);
    expect(resolveJpegQuality(75)).toBe(75);
  });

  it("rejects out-of-range and non-integer values", () => {
    expect(() => resolveJpegQuality(0)).toThrow(RangeError);
    expect(() => resolveJpegQuality(101)).toThrow(RangeError);
    expect(() => resolveJpegQuality(90.5)).toThrow(RangeError);
  });
});

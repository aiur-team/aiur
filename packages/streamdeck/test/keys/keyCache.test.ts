import { describe, expect, it } from "vitest";

import { KeyCache } from "../../src/keys/keyCache.js";
import { type KeyContent } from "../../src/keys/keyContent.js";

const fill = (r: number, g: number, b: number): KeyContent => ({ kind: "fill", color: { r, g, b } });
const image = (bytes: number[]): KeyContent => ({ kind: "image", jpeg: new Uint8Array(bytes) });

describe("KeyCache dirty tracking", () => {
  it("paints an unseen key and treats identical content as clean", () => {
    const cache = new KeyCache();
    expect(cache.isDirty(0, fill(1, 2, 3))).toBe(true);
    expect(cache.paint(0, fill(1, 2, 3))).not.toBeNull();
    expect(cache.isDirty(0, fill(1, 2, 3))).toBe(false);
    expect(cache.paint(0, fill(1, 2, 3))).toBeNull();
  });

  it("repaints only when content changes", () => {
    const cache = new KeyCache();
    cache.paint(2, image([1, 2, 3]));
    expect(cache.paint(2, image([1, 2, 3]))).toBeNull();
    const reports = cache.paint(2, image([1, 2, 4]));
    expect(reports).not.toBeNull();
  });

  it("paintAll returns paints only for changed keys, in ascending order", () => {
    const cache = new KeyCache();
    const first = cache.paintAll(
      new Map([
        [0, fill(0, 0, 0)],
        [1, image([1])],
        [3, fill(9, 9, 9)],
      ]),
    );
    expect(first.map((p) => p.index)).toEqual([0, 1, 3]);
    // Each paint carries real, non-empty reports (fill -> 1, image -> >=1).
    expect(first.every((p) => p.reports.length >= 1)).toBe(true);
    expect(first[0].reports[0].readUInt8(1)).toBe(0x06); // fill command
    expect(first[1].reports[0].readUInt8(1)).toBe(0x07); // image command

    // One key changes -> exactly one paint.
    const second = cache.paintAll(
      new Map([
        [0, fill(0, 0, 0)], // unchanged
        [1, image([2])], // changed
        [3, fill(9, 9, 9)], // unchanged
      ]),
    );
    expect(second.map((p) => p.index)).toEqual([1]);
  });

  it("invalidate(index) forces a single repaint; invalidate() forces all", () => {
    const cache = new KeyCache();
    cache.paint(0, fill(1, 1, 1));
    cache.paint(1, fill(2, 2, 2));

    cache.invalidate(0);
    expect(cache.paint(0, fill(1, 1, 1))).not.toBeNull();
    expect(cache.paint(1, fill(2, 2, 2))).toBeNull();

    cache.invalidate();
    expect(cache.paint(1, fill(2, 2, 2))).not.toBeNull();
  });

  it("does not alias the caller's buffer after paint", () => {
    const cache = new KeyCache();
    const jpeg = new Uint8Array([5, 6, 7]);
    cache.paint(0, { kind: "image", jpeg });
    jpeg[0] = 0; // mutate caller buffer
    // Cache still sees the original content as clean.
    expect(cache.isDirty(0, { kind: "image", jpeg: new Uint8Array([5, 6, 7]) })).toBe(false);
  });

  it("does not alias the caller's fill colour after paint", () => {
    const cache = new KeyCache();
    const color = { r: 100, g: 50, b: 25 };
    cache.paint(0, { kind: "fill", color });
    color.r = 0; // mutate caller's colour
    expect(cache.isDirty(0, { kind: "fill", color: { r: 100, g: 50, b: 25 } })).toBe(false);
  });

  it("honours the configured fill index base", () => {
    const cache = new KeyCache("key-count-offset");
    const reports = cache.paint(0, fill(1, 2, 3));
    expect(reports?.[0].readUInt8(2)).toBe(8);
  });

  it("validates key indices on every entry point", () => {
    const cache = new KeyCache();
    expect(() => cache.isDirty(8, fill(0, 0, 0))).toThrow(RangeError);
    expect(() => cache.paint(8, fill(0, 0, 0))).toThrow(RangeError);
    expect(() => cache.invalidate(8)).toThrow(RangeError);
  });
});

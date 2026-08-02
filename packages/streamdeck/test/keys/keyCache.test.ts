import { describe, expect, it } from "vitest";

import { KeyCache } from "../../src/keys/keyCache.js";
import { type KeyContent } from "../../src/keys/keyContent.js";
import {
  KeyWriteCancelledError,
  KeyWriteQueue,
  PartialKeyWriteError,
} from "../../src/keys/writeQueue.js";

const fill = (r: number, g: number, b: number): KeyContent => ({ kind: "fill", color: { r, g, b } });
const image = (bytes: number[]): KeyContent => ({ kind: "image", jpeg: new Uint8Array(bytes) });

// Paint and commit in one step, modelling a successful write.
const paintAndCommit = (cache: KeyCache, index: number, content: KeyContent): void => {
  cache.paint(index, content)?.commit();
};

describe("KeyCache dirty tracking", () => {
  it("paints an unseen key and treats identical content as clean once committed", () => {
    const cache = new KeyCache();
    expect(cache.isDirty(0, fill(1, 2, 3))).toBe(true);

    const paint = cache.paint(0, fill(1, 2, 3));
    expect(paint).not.toBeNull();
    // The committed cache is unchanged, but the pending write coalesces an
    // identical state tick so slow USB cannot queue duplicate transfers.
    expect(cache.isDirty(0, fill(1, 2, 3))).toBe(false);

    paint?.commit();
    expect(cache.isDirty(0, fill(1, 2, 3))).toBe(false);
    expect(cache.paint(0, fill(1, 2, 3))).toBeNull();
  });

  it("retries identical content after the queue rejects its write", async () => {
    const cache = new KeyCache();
    const queue = new KeyWriteQueue(async () => {
      throw new Error("device unavailable");
    });
    const first = cache.paint(0, fill(1, 2, 3));
    await expect(queue.enqueue(first!)).rejects.toThrow("device unavailable");
    // Queue failure discards the pending snapshot, so the retry is dirty.
    expect(cache.paint(0, fill(1, 2, 3))).not.toBeNull();
  });

  it("coalesces pending work and preserves a newer desired state", () => {
    const cache = new KeyCache();
    paintAndCommit(cache, 0, fill(1, 1, 1));

    const toB = cache.paint(0, fill(2, 2, 2));
    expect(toB).not.toBeNull();
    // A repeated tick while B is waiting must not upload B again.
    expect(cache.paint(0, fill(2, 2, 2))).toBeNull();

    // A newer A supersedes queued/in-flight B. B completing first must not
    // erase this desired A or make the final A paint disappear.
    const backToA = cache.paint(0, fill(1, 1, 1));
    expect(backToA).not.toBeNull();
    // Cancelling B must not discard the newer pending A.
    toB?.discard();
    expect(cache.paint(0, fill(1, 1, 1))).toBeNull();
    toB?.commit();
    expect(cache.paint(0, fill(1, 1, 1))).toBeNull();
    backToA?.commit();
    expect(cache.isDirty(0, fill(1, 1, 1))).toBe(false);
  });

  it("repaints after a partial transfer cancels a newer state reversal", async () => {
    const cache = new KeyCache();
    paintAndCommit(cache, 0, fill(1, 1, 1));
    const toB = cache.paint(0, image(Array.from({ length: 1017 }, () => 2)));
    const backToA = cache.paint(0, fill(1, 1, 1));
    let writes = 0;
    const queue = new KeyWriteQueue(async () => {
      writes += 1;
      if (writes === 2) throw new Error("mid-transfer");
    });

    const failed = queue.enqueue(toB!);
    const cancelled = queue.enqueue(backToA!);
    await expect(failed).rejects.toBeInstanceOf(PartialKeyWriteError);
    await expect(cancelled).rejects.toThrow(/halted/);

    // B reached the device before failing, so cached A is no longer trusted.
    expect(cache.paint(0, fill(1, 1, 1))).not.toBeNull();
  });

  it("repaints after clear cancels a newer paint during an active same-key write", async () => {
    const cache = new KeyCache();
    paintAndCommit(cache, 0, fill(1, 1, 1));
    const toB = cache.paint(0, fill(2, 2, 2));
    const toC = cache.paint(0, fill(3, 3, 3));
    let finishActive: (() => void) | undefined;
    const queue = new KeyWriteQueue(
      () =>
        new Promise<void>((resolve) => {
          finishActive = resolve;
        }),
    );

    const active = queue.enqueue(toB!);
    const cancelled = queue.enqueue(toC!);
    await new Promise((resolve) => setTimeout(resolve, 0));
    queue.clear();
    await expect(cancelled).rejects.toBeInstanceOf(KeyWriteCancelledError);
    finishActive?.();
    await active;

    // B reached the device, but C was cancelled while it was active. The old
    // committed A must not suppress the next render after that ambiguity.
    expect(cache.paint(0, fill(1, 1, 1))).not.toBeNull();
  });

  it("repaints only when content changes", () => {
    const cache = new KeyCache();
    paintAndCommit(cache, 2, image([1, 2, 3]));
    expect(cache.paint(2, image([1, 2, 3]))).toBeNull();
    expect(cache.paint(2, image([1, 2, 4]))).not.toBeNull();
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
    expect(first[0].reports[0].data.readUInt8(1)).toBe(0x06); // fill command
    expect(first[1].reports[0].data.readUInt8(1)).toBe(0x07); // image command

    // Commit the writes, then a single content change -> exactly one paint.
    for (const paint of first) paint.commit();
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
    paintAndCommit(cache, 0, fill(1, 1, 1));
    paintAndCommit(cache, 1, fill(2, 2, 2));

    cache.invalidate(0);
    expect(cache.paint(0, fill(1, 1, 1))).not.toBeNull();
    expect(cache.paint(1, fill(2, 2, 2))).toBeNull();

    cache.invalidate();
    expect(cache.paint(1, fill(2, 2, 2))).not.toBeNull();
  });

  it("does not alias the caller's buffer after a committed paint", () => {
    const cache = new KeyCache();
    const jpeg = new Uint8Array([5, 6, 7]);
    paintAndCommit(cache, 0, { kind: "image", jpeg });
    jpeg[0] = 0; // mutate caller buffer
    // Cache still sees the original content as clean.
    expect(cache.isDirty(0, { kind: "image", jpeg: new Uint8Array([5, 6, 7]) })).toBe(false);
  });

  it("does not alias the caller's fill colour after a committed paint", () => {
    const cache = new KeyCache();
    const color = { r: 100, g: 50, b: 25 };
    paintAndCommit(cache, 0, { kind: "fill", color });
    color.r = 0; // mutate caller's colour
    expect(cache.isDirty(0, { kind: "fill", color: { r: 100, g: 50, b: 25 } })).toBe(false);
  });

  it("honours the configured fill index base", () => {
    const cache = new KeyCache("key-count-offset");
    const paint = cache.paint(0, fill(1, 2, 3));
    expect(paint?.reports[0].data.readUInt8(2)).toBe(8);
  });

  it("validates key indices on every entry point", () => {
    const cache = new KeyCache();
    expect(() => cache.isDirty(8, fill(0, 0, 0))).toThrow(RangeError);
    expect(() => cache.paint(8, fill(0, 0, 0))).toThrow(RangeError);
    expect(() => cache.invalidate(8)).toThrow(RangeError);
  });
});

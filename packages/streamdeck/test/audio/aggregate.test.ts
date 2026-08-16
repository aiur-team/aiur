import { describe, expect, it, vi } from "vitest";
import { TARGET_FRAME_BYTES, createChunkAggregator } from "../../src/audio/aggregate.js";

/** A capture-sized chunk: `length` bytes counting up from `start`. */
const ramp = (start: number, length: number): Uint8Array =>
  Uint8Array.from({ length }, (_unused, index) => (start + index) & 0xff);

describe("chunk aggregator", () => {
  it("declares 100 ms of 16 kHz mono s16le as the frame size", () => {
    expect(TARGET_FRAME_BYTES).toBe(3_200);
  });

  it("rejects a frame size that can never be reached", () => {
    expect(() => createChunkAggregator(vi.fn(), 0)).toThrow(/targetBytes must be positive/);
    expect(() => createChunkAggregator(vi.fn(), -1)).toThrow(/targetBytes must be positive/);
  });

  it("ignores empty chunks", () => {
    const onFrame = vi.fn();
    const aggregator = createChunkAggregator(onFrame, 4);
    aggregator.push(new Uint8Array(0));
    aggregator.flush();
    expect(onFrame).not.toHaveBeenCalled();
  });

  it("holds chunks back until the target is reached, then emits exactly one frame", () => {
    const frames: Uint8Array[] = [];
    const aggregator = createChunkAggregator((frame) => frames.push(frame), 6);

    aggregator.push(new Uint8Array([1, 2]));
    aggregator.push(new Uint8Array([3, 4]));
    expect(frames).toEqual([]);

    aggregator.push(new Uint8Array([5, 6]));

    // Byte order matters: audio reassembled out of order is noise.
    expect(frames).toHaveLength(1);
    expect(Array.from(frames[0] as Uint8Array)).toEqual([1, 2, 3, 4, 5, 6]);
  });

  it("emits one frame for a single oversized chunk rather than splitting it", () => {
    const frames: Uint8Array[] = [];
    const aggregator = createChunkAggregator((frame) => frames.push(frame), 4);

    aggregator.push(new Uint8Array([1, 2, 3, 4, 5, 6, 7]));

    expect(frames).toHaveLength(1);
    expect(Array.from(frames[0] as Uint8Array)).toEqual([1, 2, 3, 4, 5, 6, 7]);
  });

  it("emits the short tail on flush so the last word is not clipped", () => {
    const frames: Uint8Array[] = [];
    const aggregator = createChunkAggregator((frame) => frames.push(frame), 8);

    aggregator.push(new Uint8Array([9, 8, 7]));
    aggregator.flush();

    expect(frames).toHaveLength(1);
    expect(Array.from(frames[0] as Uint8Array)).toEqual([9, 8, 7]);
  });

  it("emits nothing when flush finds an empty buffer", () => {
    const onFrame = vi.fn();
    const aggregator = createChunkAggregator(onFrame, 4);

    aggregator.flush();
    aggregator.push(new Uint8Array([1, 2, 3, 4]));
    aggregator.flush();

    // The full frame drained on push; the trailing flush has nothing left.
    expect(onFrame).toHaveBeenCalledOnce();
  });

  it("discards buffered audio on reset without emitting it", () => {
    const onFrame = vi.fn();
    const aggregator = createChunkAggregator(onFrame, 8);

    aggregator.push(new Uint8Array([1, 2, 3]));
    aggregator.reset();
    aggregator.flush();

    expect(onFrame).not.toHaveBeenCalled();
  });

  it("starts a clean frame after a reset", () => {
    const frames: Uint8Array[] = [];
    const aggregator = createChunkAggregator((frame) => frames.push(frame), 4);

    aggregator.push(new Uint8Array([1, 2, 3]));
    aggregator.reset();
    aggregator.push(new Uint8Array([7, 7, 7, 7]));

    expect(Array.from(frames[0] as Uint8Array)).toEqual([7, 7, 7, 7]);
  });

  it("keeps grouping correctly after a drain", () => {
    const frames: Uint8Array[] = [];
    const aggregator = createChunkAggregator((frame) => frames.push(frame), 4);

    aggregator.push(new Uint8Array([1, 2, 3, 4]));
    aggregator.push(new Uint8Array([5, 6]));
    expect(frames).toHaveLength(1);

    aggregator.push(new Uint8Array([7, 8]));

    // The second frame must not carry any of the first frame's bytes.
    expect(frames).toHaveLength(2);
    expect(Array.from(frames[1] as Uint8Array)).toEqual([5, 6, 7, 8]);
  });

  it("regroups real capture chunks into default-sized frames", () => {
    const frames: Uint8Array[] = [];
    const aggregator = createChunkAggregator((frame) => frames.push(frame));

    // 20 ms of 16 kHz mono s16le is 640 bytes, so five chunks make one frame.
    for (let index = 0; index < 5; index += 1) aggregator.push(ramp(index, 640));

    expect(frames).toHaveLength(1);
    expect(frames[0]?.length).toBe(TARGET_FRAME_BYTES);
    expect(frames[0]?.[0]).toBe(0);
    expect(frames[0]?.[640]).toBe(1);
    expect(frames[0]?.[1_280]).toBe(2);
  });
});

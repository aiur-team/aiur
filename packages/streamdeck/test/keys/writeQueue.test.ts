import { describe, expect, it } from "vitest";

import { type KeyPaint } from "../../src/keys/keyCache.js";
import { type KeyReport } from "../../src/keys/keyImage.js";
import {
  KeyWriteCancelledError,
  KeyWriteQueue,
  PartialKeyWriteError,
  type ReportWriter,
} from "../../src/keys/writeQueue.js";

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

// Report ordinal `i` of key `index`, tagged so a writer can identify it.
const report = (index: number, i: number): KeyReport => ({
  kind: "output",
  data: Buffer.from([index, i]),
});

const paint = (
  index: number,
  reportCount: number,
  onCommit: () => void = () => {},
  onDiscard: () => void = () => {},
): KeyPaint => ({
  index,
  reports: Array.from({ length: reportCount }, (_, i) => report(index, i)),
  commit: onCommit,
  discard: onDiscard,
});

describe("KeyWriteQueue", () => {
  it("writes reports in order and never concurrently", async () => {
    let inFlight = false;
    const order: string[] = [];
    const write: ReportWriter = async ({ data }) => {
      expect(inFlight).toBe(false); // proves no concurrent writes
      inFlight = true;
      await flush();
      order.push(`${data[0]}:${data[1]}`);
      inFlight = false;
    };

    const queue = new KeyWriteQueue(write);
    await Promise.all([queue.enqueue(paint(0, 2)), queue.enqueue(paint(1, 2))]);

    expect(order).toEqual(["0:0", "0:1", "1:0", "1:1"]);
  });

  it("commits a paint only after every report is written", async () => {
    const committed: number[] = [];
    const queue = new KeyWriteQueue(async () => {});
    await queue.enqueue(paint(5, 3, () => committed.push(5)));
    expect(committed).toEqual([5]);
  });

  it("resolves an empty paint with no writes but still commits", async () => {
    const written: KeyReport[] = [];
    let committed = false;
    const queue = new KeyWriteQueue(async (r) => {
      written.push(r);
    });
    await queue.enqueue({ index: 0, reports: [], commit: () => (committed = true), discard: () => {} });
    expect(written).toHaveLength(0);
    expect(committed).toBe(true);
  });

  it("does not replace a healthy writer between a key's reports", () => {
    const queue = new KeyWriteQueue(async () => {});

    expect(queue.reset(async () => {})).toBe(false);
    expect(queue.isHalted).toBe(false);
  });

  it("is all-or-nothing: clear() cannot truncate a paint already writing", async () => {
    const resolvers: Array<() => void> = [];
    const written: KeyReport[] = [];
    const discarded: number[] = [];
    const write: ReportWriter = (report) =>
      new Promise<void>((resolve) => {
        written.push(report);
        resolvers.push(resolve);
      });

    const queue = new KeyWriteQueue(write);
    const pA = queue.enqueue(paint(0, 2)); // 2 reports, will be mid-write
    const pB = queue.enqueue(paint(1, 1, () => {}, () => discarded.push(1))); // still pending, should be dropped

    await flush(); // A's first report is now in flight
    expect(written).toHaveLength(1);
    expect(queue.size).toBe(1); // B waiting

    queue.clear(); // drop B; A untouched
    await expect(pB).rejects.toBeInstanceOf(KeyWriteCancelledError);
    expect(discarded).toEqual([1]);
    expect(queue.size).toBe(0);

    // A completes both of its reports despite the clear.
    resolvers[0]();
    await flush();
    expect(written).toHaveLength(2);
    resolvers[1]();
    await expect(pA).resolves.toBeUndefined();

    // No report from B was ever written.
    expect(written.every((r) => r.data[0] === 0)).toBe(true);
  });

  it("halts after a clean first-report failure to avoid writes to a recovering backend", async () => {
    const committed: number[] = [];
    const write: ReportWriter = async ({ data }) => {
      if (data[0] === 0) throw new Error("boom");
    };
    const queue = new KeyWriteQueue(write);
    const pA = queue.enqueue(paint(0, 1, () => committed.push(0)));
    const pB = queue.enqueue(paint(1, 1, () => committed.push(1)));

    await expect(pA).rejects.toThrow("boom");
    await expect(pB).rejects.toBeInstanceOf(KeyWriteCancelledError);
    // No key commits while the runtime is closing/reopening the failed handle.
    expect(committed).toEqual([]);
    expect(queue.isHalted).toBe(true);
    await expect(queue.enqueue(paint(2, 1))).rejects.toBeInstanceOf(KeyWriteCancelledError);
    expect(queue.reset()).toBe(false);
    expect(queue.isHalted).toBe(true);
  });

  it("halts with PartialKeyWriteError when a write fails mid-sequence", async () => {
    const committed: number[] = [];
    // Fail on the SECOND report of key 0 — a report is already on the wire.
    const write: ReportWriter = async ({ data }) => {
      if (data[0] === 0 && data[1] === 1) throw new Error("mid-transfer");
    };
    const queue = new KeyWriteQueue(write);
    const pA = queue.enqueue(paint(0, 3, () => committed.push(0)));
    const pB = queue.enqueue(paint(1, 1, () => committed.push(1)));

    const err = await pA.catch((e: unknown) => e);
    expect(err).toBeInstanceOf(PartialKeyWriteError);
    expect((err as PartialKeyWriteError).keyIndex).toBe(0);
    expect((err as PartialKeyWriteError).reportsWritten).toBe(1);
    expect((err as PartialKeyWriteError).reportsTotal).toBe(3);

    // The queue halts: the pending paint is cancelled, nothing committed.
    await expect(pB).rejects.toBeInstanceOf(KeyWriteCancelledError);
    expect(committed).toEqual([]);
    expect(queue.isHalted).toBe(true);

    // Existing argument-less reset calls are safe no-ops; recovery must provide
    // a writer for the newly opened backend before this queue can resume.
    await expect(queue.enqueue(paint(2, 1))).rejects.toBeInstanceOf(KeyWriteCancelledError);
    expect(queue.reset(async () => {})).toBe(true);
    expect(queue.isHalted).toBe(false);
    await expect(queue.enqueue(paint(2, 1))).resolves.toBeUndefined();
  });

  it("carries a default cancellation message", () => {
    expect(new KeyWriteCancelledError().message).toMatch(/cancelled/);
  });
});

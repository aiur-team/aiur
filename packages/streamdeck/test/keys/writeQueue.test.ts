import { describe, expect, it } from "vitest";

import { type KeyPaint } from "../../src/keys/keyCache.js";
import {
  KeyWriteCancelledError,
  KeyWriteQueue,
  type ReportWriter,
} from "../../src/keys/writeQueue.js";

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

const paint = (index: number, reportCount: number): KeyPaint => ({
  index,
  reports: Array.from({ length: reportCount }, (_, i) => Buffer.from([index, i])),
});

describe("KeyWriteQueue", () => {
  it("writes reports in order and never concurrently", async () => {
    let inFlight = false;
    const order: string[] = [];
    const write: ReportWriter = async (report) => {
      expect(inFlight).toBe(false); // proves no concurrent writes
      inFlight = true;
      await flush();
      order.push(`${report[0]}:${report[1]}`);
      inFlight = false;
    };

    const queue = new KeyWriteQueue(write);
    await Promise.all([queue.enqueue(paint(0, 2)), queue.enqueue(paint(1, 2))]);

    expect(order).toEqual(["0:0", "0:1", "1:0", "1:1"]);
  });

  it("resolves an empty paint with no writes", async () => {
    const written: Buffer[] = [];
    const queue = new KeyWriteQueue(async (r) => {
      written.push(r);
    });
    await queue.enqueue({ index: 0, reports: [] });
    expect(written).toHaveLength(0);
  });

  it("is all-or-nothing: clear() cannot truncate a paint already writing", async () => {
    const resolvers: Array<() => void> = [];
    const written: Buffer[] = [];
    const write: ReportWriter = (report) =>
      new Promise<void>((resolve) => {
        written.push(report);
        resolvers.push(resolve);
      });

    const queue = new KeyWriteQueue(write);
    const pA = queue.enqueue(paint(0, 2)); // 2 reports, will be mid-write
    const pB = queue.enqueue(paint(1, 1)); // still pending, should be dropped

    await flush(); // A's first report is now in flight
    expect(written).toHaveLength(1);
    expect(queue.size).toBe(1); // B waiting

    queue.clear(); // drop B; A untouched
    await expect(pB).rejects.toBeInstanceOf(KeyWriteCancelledError);
    expect(queue.size).toBe(0);

    // A completes both of its reports despite the clear.
    resolvers[0]();
    await flush();
    expect(written).toHaveLength(2);
    resolvers[1]();
    await expect(pA).resolves.toBeUndefined();

    // No report from B was ever written.
    expect(written.every((r) => r[0] === 0)).toBe(true);
  });

  it("rejects the failing paint but keeps draining the rest", async () => {
    const write: ReportWriter = async (report) => {
      if (report[0] === 0) throw new Error("boom");
    };
    const queue = new KeyWriteQueue(write);
    const pA = queue.enqueue(paint(0, 1));
    const pB = queue.enqueue(paint(1, 1));

    await expect(pA).rejects.toThrow("boom");
    await expect(pB).resolves.toBeUndefined();
  });

  it("carries a default cancellation message", () => {
    expect(new KeyWriteCancelledError().message).toMatch(/cancelled/);
  });
});

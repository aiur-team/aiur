/**
 * Serialized, all-or-nothing key write queue.
 *
 * USB write throughput — not CPU — is the Stream Deck bottleneck: one key is
 * several 1KB transfers, a full-panel repaint is dozens to hundreds. Two hard
 * rules follow, and this queue enforces both:
 *
 * 1. **Serialize writes.** The device assumes strictly one transfer at a time;
 *    interleaved chunks from two keys corrupt both images. This queue runs at
 *    concurrency one — a single drain loop, never two writes in flight. Feed it
 *    an injected {@link ReportWriter} (the hidraw transfer, from #1354).
 *
 * 2. **All-or-nothing per key.** Elgato warns that a communication problem
 *    typically wedges the device until replug, and a partial image transfer is
 *    exactly such a problem. Once a key's report sequence begins writing, this
 *    queue writes every chunk to completion — it never checks for cancellation
 *    mid-key. {@link clear} therefore only drops paints that have not started;
 *    it can never truncate a transfer that is already on the wire.
 *
 * The queue owns no device handle and does no encoding; it consumes the
 * {@link KeyPaint}s produced by the cache/renderer.
 */
import { type KeyPaint } from "./keyCache.js";

/** Writes a single already-built 1024- or 32-byte report to the device. */
export type ReportWriter = (report: Buffer) => Promise<void>;

/** Rejection reason for paints dropped by {@link KeyWriteQueue.clear}. */
export class KeyWriteCancelledError extends Error {
  constructor(message = "key write cancelled before it started") {
    super(message);
    this.name = "KeyWriteCancelledError";
  }
}

interface QueuedPaint {
  readonly paint: KeyPaint;
  readonly resolve: () => void;
  readonly reject: (error: unknown) => void;
}

export class KeyWriteQueue {
  private readonly pending: QueuedPaint[] = [];
  private draining = false;

  constructor(private readonly write: ReportWriter) {}

  /** Number of paints waiting to start (excludes the one being written). */
  get size(): number {
    return this.pending.length;
  }

  /**
   * Enqueue one key paint. The returned promise resolves once every report in
   * the paint has been written to completion, or rejects if a write fails or
   * the paint is dropped by {@link clear} before it starts.
   */
  enqueue(paint: KeyPaint): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      this.pending.push({ paint, resolve, reject });
      void this.drain();
    });
  }

  /**
   * Drop every not-yet-started paint, rejecting each with
   * {@link KeyWriteCancelledError}. A paint already mid-write is untouched and
   * still completes in full — cancellation is only ever observed at key
   * boundaries, never mid-chunk.
   */
  clear(): void {
    const dropped = this.pending.splice(0, this.pending.length);
    for (const job of dropped) {
      job.reject(new KeyWriteCancelledError());
    }
  }

  private async drain(): Promise<void> {
    if (this.draining) return;
    this.draining = true;
    try {
      let job: QueuedPaint | undefined;
      while ((job = this.pending.shift()) !== undefined) {
        try {
          // All-or-nothing: write every chunk of this key with no interleaving
          // and no mid-sequence cancellation check.
          for (const report of job.paint.reports) {
            await this.write(report);
          }
          job.resolve();
        } catch (error) {
          job.reject(error);
        }
      }
    } finally {
      this.draining = false;
    }
  }
}

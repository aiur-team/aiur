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
 *    an injected {@link ReportWriter} (the hidraw transfer, from #1354), which
 *    dispatches each {@link KeyReport} by its `kind` (`hid.write()` for output
 *    reports, `sendFeatureReport()` for the RGB fill).
 *
 * 2. **All-or-nothing per key.** Elgato warns that a communication problem
 *    typically wedges the device until replug, and a partial image transfer is
 *    exactly such a problem. A paint has three outcomes:
 *
 *    - **Success** — every report is written; the paint's {@link KeyPaint.commit}
 *      runs (updating the cache) and the promise resolves.
 *    - **Clean failure** — the write throws on the *first* report, so nothing
 *      reached the wire. The paint rejects with the original error. The queue
 *      HALTS and cancels pending paints: a write failure can mean the runtime is
 *      closing a post-suspend zombie handle, so continuing to drain would commit
 *      content sent to that stale backend.
 *    - **Partial failure** — the write throws *after* one or more reports are on
 *      the wire. There is now a truncated transfer the device cannot recover
 *      from on its own, so the paint rejects with {@link PartialKeyWriteError}
 *      and the queue HALTS: every still-pending paint is rejected and no further
 *      report is written. The caller must run the #1354 key-stream + device
 *      reset and either construct a fresh writer/queue after reconnect or call
 *      {@link reset} with a fresh writer. `commit` never runs.
 *
 * Cancellation is only ever observed at key boundaries: {@link clear} drops
 * paints that have not started and can never truncate a transfer already on the
 * wire.
 *
 * The queue owns no device handle and does no encoding; it consumes the
 * {@link KeyPaint}s produced by the cache/renderer.
 */
import { type KeyPaint } from "./keyCache.js";
import { type KeyReport } from "./keyImage.js";

/** Writes a single already-built HID report, dispatched by {@link KeyReport.kind}. */
export type ReportWriter = (report: KeyReport) => Promise<void>;

/** Rejection reason for paints dropped by {@link KeyWriteQueue.clear} or a halt. */
export class KeyWriteCancelledError extends Error {
  constructor(message = "key write cancelled before it started") {
    super(message);
    this.name = "KeyWriteCancelledError";
  }
}

/**
 * A key's report sequence failed after at least one report was already written,
 * leaving a truncated transfer on the wire. The device is presumed wedged; the
 * caller must perform the #1354 key-stream and device reset, then construct a
 * fresh writer/queue against the reopened backend or pass that writer to
 * {@link KeyWriteQueue.reset} before writing again.
 */
export class PartialKeyWriteError extends Error {
  constructor(
    /** Key whose transfer was truncated. */
    readonly keyIndex: number,
    /** Number of reports that had reached the wire before the failure. */
    readonly reportsWritten: number,
    /** Total reports the paint intended to write. */
    readonly reportsTotal: number,
    /** The underlying write error. */
    readonly cause: unknown,
  ) {
    super(
      `partial write on key ${keyIndex}: ${reportsWritten}/${reportsTotal} reports on the wire before failure; device must be reset`,
    );
    this.name = "PartialKeyWriteError";
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
  private halted = false;

  constructor(private write: ReportWriter) {}

  /** Number of paints waiting to start (excludes the one being written). */
  get size(): number {
    return this.pending.length;
  }

  /**
   * True once any transport failure has halted the queue. It stays halted until
   * runtime recovery supplies a fresh writer through {@link reset}; no queued
   * paint may reuse the backend that reported the failure.
   */
  get isHalted(): boolean {
    return this.halted;
  }

  /**
   * Enqueue one key paint. The returned promise resolves once every report in
   * the paint has been written and its content committed, or rejects if a write
   * fails, the paint is dropped by {@link clear} before it starts, or the queue
   * is halted. A failure halts the queue so no pending paint can commit against
   * a backend the runtime is concurrently replacing.
   */
  enqueue(paint: KeyPaint): Promise<void> {
    if (this.halted) {
      paint.discard();
      return Promise.reject(
        new KeyWriteCancelledError("queue halted after a transport write failure; reconnect and reset with a fresh writer"),
      );
    }
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
      job.paint.discard();
      job.reject(new KeyWriteCancelledError());
    }
  }

  /**
   * Resume after #1354 recovery only with a writer bound to the newly opened
   * backend. For source compatibility, an argument-less call is a safe no-op
   * that returns `false`: it can never revive the stale writer captured before
   * the failed transfer. Calling this while healthy is also a safe no-op, so a
   * replacement can never split one key's report sequence across backends.
   */
  reset(replacement?: ReportWriter): boolean {
    if (replacement === undefined || !this.halted) return false;
    this.write = replacement;
    this.halted = false;
    return true;
  }

  private async drain(): Promise<void> {
    if (this.draining) return;
    this.draining = true;
    try {
      let job: QueuedPaint | undefined;
      while ((job = this.pending.shift()) !== undefined) {
        const { paint } = job;
        let written = 0;
        try {
          // All-or-nothing: write every chunk of this key with no interleaving
          // and no mid-sequence cancellation check.
          for (const report of paint.reports) {
            await this.write(report);
            written += 1;
          }
          // The transfer landed in full; only now is it safe to treat the key
          // as painted.
          paint.commit();
          job.resolve();
        } catch (error) {
          this.halted = true;
          if (written === 0) {
            paint.discard();
            // Nothing reached the wire, but the failed writer can still be a
            // zombie handle. Do not let pending paints commit while runtime
            // recovery closes and replaces that backend.
            job.reject(error);
          } else {
            // The key's on-device image is now unknown. Drop both committed
            // and pending cache state so recovery repaints even if a queued
            // newer desired value happens to equal the old committed value.
            paint.invalidate();
            // A truncated transfer is on the wire. Explain that condition to
            // the active paint while applying the same queue halt below.
            job.reject(new PartialKeyWriteError(paint.index, written, paint.reports.length, error));
          }
          const stranded = this.pending.splice(0, this.pending.length);
          for (const queued of stranded) {
            queued.paint.discard();
            queued.reject(
              new KeyWriteCancelledError(
                "queue halted after a transport write failure; reconnect and reset with a fresh writer",
              ),
            );
          }
          return;
        }
      }
    } finally {
      // Race-free by construction: the only `await` is inside the loop body.
      // Once `shift()` returns undefined the loop exits and this reset runs in
      // the same synchronous continuation, so no `enqueue()` can observe an
      // empty queue with `draining` still true and then be stranded. Keep it
      // that way — do not introduce an `await` between the final `shift()` and
      // this reset, or a late enqueue could deadlock.
      this.draining = false;
    }
  }
}

/**
 * Runtime-bound key report writer.
 *
 * `KeyWriteQueue` deliberately knows only about ordering and all-or-nothing
 * paint completion. This adapter is the impure edge that routes an encoded
 * report to the right HID operation and treats each attempted write as the
 * renderer's transport heartbeat. A failure therefore starts Runtime's
 * close/reopen recovery for the post-suspend zombie-handle case before the
 * queue applies its clean-versus-partial failure policy.
 */
import type { HidBackend } from "../backend.js";
import type { Runtime } from "../runtime.js";
import type { KeyReport } from "./keyImage.js";
import type { ReportWriter } from "./writeQueue.js";

/** The backend operations a key report may use. */
export type KeyReportBackend = Pick<HidBackend, "write" | "sendFeatureReport">;

/** The lifecycle recovery operation invoked after a failed key transfer. */
export type KeyWriteRuntime = Pick<Runtime, "notifyWriteFailure">;

/**
 * Makes the {@link ReportWriter} consumed by {@link KeyWriteQueue}.
 *
 * Output JPEG reports use the interrupt endpoint; RGB fills use the feature
 * endpoint. On either failure the original error is reported to the runtime,
 * then rethrown intact so the queue can preserve its per-key error and
 * partial-transfer guarantees. A broken notifier never masks the transfer
 * failure that the queue needs to classify. The returned writer is bound to
 * `backend`; after reconnect, create a fresh writer and either pass it to the
 * halted queue's `reset` method or create a fresh queue.
 */
export function createKeyReportWriter(
  backend: KeyReportBackend,
  runtime: KeyWriteRuntime,
): ReportWriter {
  return async (report: KeyReport): Promise<void> => {
    try {
      if (report.kind === "output") {
        await backend.write(report.data);
      } else {
        await backend.sendFeatureReport(report.data);
      }
    } catch (error) {
      try {
        runtime.notifyWriteFailure(error);
      } catch {
        // The transport error remains the queue's observable failure.
      }
      throw error;
    }
  };
}

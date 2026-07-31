/**
 * Classification of a single HID read result.
 *
 * Elgato's docs are explicit: a read that returns no bytes within the poll
 * window means "no event pending", **not** an error and **not** a disconnect.
 * Treating a timeout as a disconnect is what produces phantom reconnect loops,
 * so this module gives the reducer a read outcome that keeps the idle case
 * distinct from a genuine transport failure.
 *
 * Pure: it inspects a raw read result and never touches a device. The impure
 * reader (a backend poll) reports one of these shapes; the reducer in
 * {@link file://./lifecycle.ts} reacts.
 */

import { READ_LENGTH } from "./report.js";

/** A raw read result handed up from a backend poll. */
export type RawRead =
  | { kind: "bytes"; data: Uint8Array }
  | { kind: "timeout" }
  | { kind: "error"; error: unknown };

/** A classified read outcome the reducer consumes. */
export type ReadOutcome =
  | { type: "input"; data: Uint8Array }
  | { type: "idle" }
  | { type: "error"; error: unknown };

/**
 * Classifies a raw read. A timeout — or an empty/short buffer, which the
 * kernel also returns for an interval with no pending event — is `idle` and
 * never `error`. Only a real read failure is `error`, and only that outcome is
 * allowed to drive recovery.
 */
export const classifyRead = (raw: RawRead): ReadOutcome => {
  if (raw.kind === "timeout") {
    return { type: "idle" };
  }

  if (raw.kind === "error") {
    return { type: "error", error: raw.error };
  }

  if (raw.data.length < READ_LENGTH) {
    return { type: "idle" };
  }

  return { type: "input", data: raw.data };
};

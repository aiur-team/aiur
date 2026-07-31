/**
 * Pure device-lifecycle state machine for the Stream Deck + transport.
 *
 * This is the heart of the ticket: it owns the connection lifecycle across the
 * four real-world failure modes without ever touching a device. The impure
 * shell ({@link file://./runtime.ts}) feeds it events from udev, logind, the
 * reader, and process signals, then performs the {@link LifecycleEffect}s it
 * returns. Keeping the decisions here, pure and total, is what makes the
 * hard-to-reproduce transitions (suspend/resume, hotplug, shutdown) testable.
 *
 * Design notes tied to the ticket's hard requirements:
 *
 * - **Reset on startup, Show Logo on shutdown.** Opening the device emits a
 *   key-stream reset before the first paint; shutting down emits Show Logo
 *   before closing so the deck does not freeze on the last frame.
 * - **A read timeout is not a disconnect.** Timeouts never reach this reducer
 *   as events (see {@link file://./read.ts}); only a genuine `read-error`
 *   drives recovery, which avoids phantom reconnect loops.
 * - **Do not trust `connected()`.** Recovery is driven by explicit signals:
 *   udev add/remove, logind sleep/wake, and a failed write heartbeat — never a
 *   library liveness flag.
 */

/** Connection state of the device handle. */
export type LinkState = "absent" | "opening" | "open" | "reconnecting" | "suspended" | "stopped";

export interface LifecycleState {
  link: LinkState;
  /**
   * Consecutive open/read/write failures since the last successful open. Drives
   * the reconnect backoff and resets to 0 on a clean open, a fresh udev add, or
   * a resume. A physical remove also resets it: the next add starts fresh.
   */
  attempt: number;
}

/** Reconnect backoff floor in milliseconds (first retry). */
export const RECONNECT_BASE_MS = 250;
/** Reconnect backoff ceiling in milliseconds. */
export const RECONNECT_CAP_MS = 5000;
/**
 * Failure count at which a present-but-unusable device raises an operator alert.
 * By this point the backoff has reached {@link RECONNECT_CAP_MS} and the device
 * is plugged in but persistently refusing to open — worth surfacing loudly.
 */
export const RECONNECT_ALERT_AFTER = 5;

/** Backoff delay for the `attempt`-th consecutive failure (0-based). */
export const reconnectDelayMs = (attempt: number): number =>
  Math.min(RECONNECT_BASE_MS * 2 ** attempt, RECONNECT_CAP_MS);

/** Events the impure shell feeds the reducer. */
export type LifecycleEvent =
  /** udev reported a matching device add. */
  | { type: "device-added" }
  /** udev reported the device was removed. */
  | { type: "device-removed" }
  /** A backend open attempt succeeded. */
  | { type: "device-opened" }
  /** A backend open attempt failed. */
  | { type: "open-failed"; error: unknown }
  /** A genuine read failure (never a timeout — see read.ts). */
  | { type: "read-error"; error: unknown }
  /** A heartbeat write failed: the classic post-suspend zombie handle. */
  | { type: "write-failed"; error: unknown }
  /** logind PrepareForSleep(true): the machine is about to suspend. */
  | { type: "sleep" }
  /** logind PrepareForSleep(false): the machine resumed. */
  | { type: "wake" }
  /** A scheduled reconnect backoff elapsed: try opening again. */
  | { type: "reopen" }
  /** SIGTERM or SIGINT: shut down and leave the logo up. */
  | { type: "shutdown" };

/** Side effects the shell performs; the reducer itself stays pure. */
export type LifecycleEffect =
  /** Attempt to open the device handle. */
  | { type: "open-device" }
  /** Release the handle. Teardown errors are normal and must be swallowed. */
  | { type: "close-device" }
  /** Send the key-stream reset to abort any partial transfer. */
  | { type: "send-key-stream-reset" }
  /** Reapply the configured brightness (feature report). */
  | { type: "apply-brightness" }
  /** Repaint the current view. */
  | { type: "repaint" }
  /** Send the Show Logo feature report before closing (shutdown or sleep). */
  | { type: "show-logo" }
  /** Schedule a reconnect attempt after a backoff delay. */
  | { type: "schedule-reopen"; delayMs: number }
  /** Raise a loud, operator-visible alert: the device is present but unusable. */
  | { type: "alert"; code: NoticeCode; cause?: unknown }
  /** Exit the process. */
  | { type: "stop" }
  /** Emit an operator-facing notice with a stable code and the cause. */
  | { type: "notice"; code: NoticeCode; cause?: unknown };

export type NoticeCode = "open-failed" | "read-error" | "suspend-zombie";

export interface LifecycleTransition {
  state: LifecycleState;
  effects: readonly LifecycleEffect[];
}

/** Initial state: no handle, waiting for the device to appear via udev. */
export const createLifecycleState = (): LifecycleState => ({ link: "absent", attempt: 0 });

const to = (link: LinkState, effects: readonly LifecycleEffect[], attempt = 0): LifecycleTransition => ({
  state: { link, attempt },
  effects,
});

/**
 * Builds a transition into `reconnecting` after a failed open/read/write. The
 * device is (or was) present, so we do not fall back to `absent` — which only
 * a fresh udev add could ever leave, and udev will not fire again for a device
 * that is still plugged in. Instead we schedule a bounded-backoff reopen, log
 * the failure loudly (`notice`), and once the failures pile up raise an
 * `alert`. This is the fix for "a transient EIO bricks the sidecar until
 * replug".
 */
const reconnect = (
  attempt: number,
  code: NoticeCode,
  cause: unknown,
  before: readonly LifecycleEffect[],
): LifecycleTransition => {
  const next = attempt + 1;
  const effects: LifecycleEffect[] = [
    ...before,
    { type: "notice", code, cause },
    { type: "schedule-reopen", delayMs: reconnectDelayMs(attempt) },
  ];
  if (next === RECONNECT_ALERT_AFTER) {
    effects.push({ type: "alert", code, cause });
  }
  return to("reconnecting", effects, next);
};

/**
 * Advances the lifecycle. Every `(state, event)` pair is total: an event with
 * no meaningful transition from the current state leaves both state and
 * effects unchanged, which is what lets the shell fire events optimistically
 * (a duplicate udev add while already open, a wake with no handle) without
 * special-casing.
 */
export const transitionLifecycle = (state: LifecycleState, event: LifecycleEvent): LifecycleTransition => {
  switch (state.link) {
    case "absent":
      switch (event.type) {
        case "device-added":
          return to("opening", [{ type: "open-device" }]);
        case "shutdown":
          return to("stopped", [{ type: "stop" }]);
        default:
          return { state, effects: [] };
      }

    case "opening":
      switch (event.type) {
        case "device-opened":
          return to("open", [{ type: "send-key-stream-reset" }, { type: "apply-brightness" }, { type: "repaint" }]);
        case "open-failed":
          return reconnect(state.attempt, "open-failed", event.error, []);
        case "device-removed":
          return to("absent", [{ type: "close-device" }]);
        case "sleep":
          return to("suspended", [{ type: "close-device" }]);
        case "shutdown":
          return to("stopped", [{ type: "close-device" }, { type: "stop" }]);
        default:
          return { state, effects: [] };
      }

    case "open":
      switch (event.type) {
        case "device-removed":
          return to("absent", [{ type: "close-device" }]);
        case "read-error":
          return reconnect(state.attempt, "read-error", event.error, [{ type: "close-device" }]);
        case "write-failed":
          // The classic post-suspend zombie: connected() lies. Close and
          // reconnect with the same bounded backoff so opens-succeed/writes-fail
          // cannot drive an unbounded close/open cycle at the write cadence.
          return reconnect(state.attempt, "suspend-zombie", event.error, [{ type: "close-device" }]);
        case "sleep":
          // Leave the logo up before suspending too: skip it and the deck
          // freezes on the last painted frame while the machine sleeps.
          return to("suspended", [{ type: "show-logo" }, { type: "close-device" }]);
        case "shutdown":
          return to("stopped", [{ type: "show-logo" }, { type: "close-device" }, { type: "stop" }]);
        default:
          return { state, effects: [] };
      }

    case "reconnecting":
      switch (event.type) {
        case "reopen":
          return to("opening", [{ type: "open-device" }], state.attempt);
        case "device-added":
          // A fresh udev add means the node is back: reset the backoff and open
          // now rather than waiting out the scheduled delay.
          return to("opening", [{ type: "open-device" }]);
        case "device-removed":
          return to("absent", [{ type: "close-device" }]);
        case "sleep":
          return to("suspended", [{ type: "close-device" }]);
        case "shutdown":
          return to("stopped", [{ type: "close-device" }, { type: "stop" }]);
        default:
          return { state, effects: [] };
      }

    case "suspended":
      switch (event.type) {
        case "wake":
          return to("opening", [{ type: "open-device" }]);
        case "device-removed":
          return to("absent", [{ type: "close-device" }]);
        case "shutdown":
          return to("stopped", [{ type: "close-device" }, { type: "stop" }]);
        default:
          return { state, effects: [] };
      }

    case "stopped":
      return { state, effects: [] };
  }
};

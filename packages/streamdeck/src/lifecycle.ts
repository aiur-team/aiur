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
export type LinkState = "absent" | "opening" | "open" | "suspended" | "stopped";

export interface LifecycleState {
  link: LinkState;
}

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
  /** Send the Show Logo feature report before closing on shutdown. */
  | { type: "show-logo" }
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
export const createLifecycleState = (): LifecycleState => ({ link: "absent" });

const to = (link: LinkState, effects: readonly LifecycleEffect[]): LifecycleTransition => ({
  state: { link },
  effects,
});

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
          return to("absent", [{ type: "notice", code: "open-failed", cause: event.error }]);
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
          return to("absent", [{ type: "close-device" }, { type: "notice", code: "read-error", cause: event.error }]);
        case "write-failed":
          return to("opening", [
            { type: "close-device" },
            { type: "notice", code: "suspend-zombie", cause: event.error },
            { type: "open-device" },
          ]);
        case "sleep":
          return to("suspended", [{ type: "close-device" }]);
        case "shutdown":
          return to("stopped", [{ type: "show-logo" }, { type: "close-device" }, { type: "stop" }]);
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

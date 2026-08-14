/**
 * Impure shell that drives the lifecycle reducer with real event sources.
 *
 * It owns the mutable transport handle and the "perform each effect" side of
 * the pure {@link transitionLifecycle} reducer: it opens/closes the backend,
 * sends the startup reset and shutdown Show Logo, reapplies brightness, drives
 * the input poll loop, and translates udev / logind / signal events into
 * reducer events. Every side-effecting primitive (spawn, net, backend factory,
 * timers, signal registration, exit, logging) is injected, so the whole shell
 * is testable with fakes and the real wiring lives only in
 * {@link file://./main.ts}.
 */

import type { HidBackend } from "./backend.js";
import { classifyRead } from "./read.js";
import { acquireLock, createAbstractSocketBinding, DEFAULT_LOCK_NAME, type LockHandle, type NetLike } from "./lock.js";
import {
  createLifecycleState,
  transitionLifecycle,
  type LifecycleEffect,
  type LifecycleEvent,
  type LifecycleState,
} from "./lifecycle.js";
import type { SpawnLike, LineSubscription } from "./line-source.js";
import { createSleepSource } from "./sleep-source.js";
import { createUdevSource } from "./udev-source.js";
import { keyStreamReset, setBrightness, showLogo, POLL_INTERVAL_MS } from "./report.js";

/** Monitor-subprocess restart backoff floor in milliseconds. */
export const MONITOR_RESTART_BASE_MS = 500;
/** Monitor-subprocess restart backoff ceiling in milliseconds. */
export const MONITOR_RESTART_CAP_MS = 30_000;

/** Structured operator-facing log line. */
export interface LogEntry {
  level: "info" | "warn" | "error";
  message: string;
  cause?: unknown;
}

export interface RuntimeEnv {
  /** Injected `node:child_process` spawn for the monitor CLIs. */
  spawn: SpawnLike;
  /** Injected `node:net` for the advisory lock. */
  net: NetLike;
  /** Opens a freshly-constructed transport backend for the current device. */
  openBackend(): Promise<HidBackend>;
  /** Registers a SIGTERM/SIGINT handler. */
  registerSignals(handler: () => void): void;
  /** Terminates the process after the logo is left up. */
  exit(): void;
  /** Timer primitives (injected so the poll loop is testable). */
  setTimer(fn: () => void, ms: number): unknown;
  clearTimer(handle: unknown): void;
  /** Operator log sink. */
  log(entry: LogEntry): void;
  /** Brightness (0–100) reapplied on open/resume. */
  brightness: number;
  /** True if the device node already exists at startup (skip waiting on udev). */
  devicePresentAtStart: boolean;
  /** Renderer hook for an input report; the render ticket owns the body. */
  onInput?(data: Uint8Array): void;
  /** Renderer hook to repaint the current view. */
  repaint?(backend: HidBackend): Promise<void>;
  /** Clears the renderer's reference when a handle is unplugged or recycled. */
  onBackendClosed(backend: HidBackend | null): void;
  /** Lock name; defaults to {@link DEFAULT_LOCK_NAME}. */
  lockName?: string;
}

/** A started runtime; {@link stop} tears down sources and the lock. */
export interface Runtime {
  stop(): void;
  /**
   * Reports a failed device write (a heartbeat write the renderer performs).
   * A failed write is how the post-suspend zombie is caught — `connected()`
   * still says true, but the handle is dead — so this drives a close/reopen.
   * The writer owns the heartbeat cadence; the transport owns the recovery.
   */
  notifyWriteFailure(error: unknown): void;
}

/**
 * Acquires the advisory lock, wires the event sources, and runs the lifecycle
 * until shutdown. Rejects if the lock is already held (a second instance).
 */
export const startRuntime = async (env: RuntimeEnv): Promise<Runtime> => {
  const lock = await acquireLock(env.lockName ?? DEFAULT_LOCK_NAME, createAbstractSocketBinding(env.net));

  let state: LifecycleState = createLifecycleState();
  let backend: HidBackend | null = null;
  let pollTimer: unknown = null;
  let reopenTimer: unknown = null;
  // Effects are performed one at a time in dispatch order: the reducer runs
  // synchronously and mutates `state`, while their (async) side effects are
  // serialized here so, e.g., the startup key-stream reset lands before the
  // first repaint.
  let effectChain: Promise<void> = Promise.resolve();

  const stopPolling = (): void => {
    if (pollTimer !== null) {
      env.clearTimer(pollTimer);
      pollTimer = null;
    }
  };

  const cancelReopen = (): void => {
    if (reopenTimer !== null) {
      env.clearTimer(reopenTimer);
      reopenTimer = null;
    }
  };

  const dispatch = (event: LifecycleEvent): void => {
    const { state: next, effects } = transitionLifecycle(state, event);
    state = next;
    for (const effect of effects) {
      // Guard each effect so a throwing effect (e.g. a rejecting repaint hook)
      // is logged and never poisons the chain, which would silently drop every
      // subsequent effect and leave an unhandled rejection.
      effectChain = effectChain
        .then(() => perform(effect))
        .catch((cause) => env.log({ level: "error", message: `effect failed: ${effect.type}`, cause }));
    }
  };

  const scheduledPoll = (delayMs: number = POLL_INTERVAL_MS): void => {
    pollTimer = env.setTimer(() => {
      pollTimer = null;
      void poll();
    }, delayMs);
  };

  const poll = async (): Promise<void> => {
    const current = backend;
    if (current === null || state.link !== "open") {
      return;
    }
    const outcome = classifyRead(await current.read());
    if (backend !== current || state.link !== "open") {
      return;
    }
    if (outcome.type === "error") {
      dispatch({ type: "read-error", error: outcome.error });
      return;
    }
    if (outcome.type === "input") {
      env.onInput?.(outcome.data);
      // Read again immediately rather than waiting out the interval: a backend
      // may have several reports buffered, and draining one per interval makes
      // a fast dial spin keep scrolling long after the operator stopped. Going
      // through a zero-delay timer rather than recursing keeps the loop
      // interruptible and bounded — an idle read still blocks for a full
      // interval, so a quiet device costs nothing extra.
      scheduledPoll(0);
      return;
    }
    scheduledPoll();
  };

  // open-device and close-device only ever run as serialized effects (see the
  // effect chain above), so they never overlap: there is no in-flight open to
  // invalidate here.
  const openDevice = async (): Promise<void> => {
    // A pending backoff reopen is now moot: we are opening right now.
    cancelReopen();
    try {
      backend = await env.openBackend();
      dispatch({ type: "device-opened" });
      // Begin polling for input reports now that the handle is open.
      scheduledPoll();
    } catch (error) {
      dispatch({ type: "open-failed", error });
    }
  };

  const closeDevice = async (): Promise<void> => {
    stopPolling();
    cancelReopen();
    const closing = backend;
    backend = null;
    env.onBackendClosed(closing);
    // Teardown errors are normal on unplug; swallow them.
    await closing?.close().catch(() => undefined);
  };

  const sendFeature = async (report: Uint8Array, label: string): Promise<void> => {
    try {
      await backend?.sendFeatureReport(report);
    } catch (cause) {
      env.log({ level: "warn", message: `feature report unavailable: ${label}`, cause });
    }
  };

  const perform = async (effect: LifecycleEffect): Promise<void> => {
    switch (effect.type) {
      case "open-device":
        return openDevice();
      case "close-device":
        return closeDevice();
      case "send-key-stream-reset":
        return void backend?.write(keyStreamReset()).catch((cause) =>
          env.log({ level: "warn", message: "key-stream reset failed", cause }),
        );
      case "apply-brightness":
        return sendFeature(setBrightness(env.brightness), "brightness");
      case "repaint":
        // repaint is only ever emitted immediately after a successful open
        // (device-opened), so the handle is non-null here by construction.
        await env.repaint?.(backend as HidBackend);
        // Writes reached the device: the link is proven, so the reconnect
        // backoff can reset. A throw here skips this and leaves the backoff
        // growing, which is what stops a wedged deck reconnecting forever.
        dispatch({ type: "link-healthy" });
        return;
      case "show-logo":
        return sendFeature(showLogo(), "show-logo");
      case "schedule-reopen":
        reopenTimer = env.setTimer(() => {
          reopenTimer = null;
          dispatch({ type: "reopen" });
        }, effect.delayMs);
        return;
      case "alert":
        // Present-but-unusable device: retries have reached the backoff cap and
        // it still will not open. This is the loud case an operator must see.
        env.log({
          level: "error",
          message: `Stream Deck present but not opening after repeated attempts (${effect.code}); check permissions/udev ACL and cabling`,
          cause: effect.cause,
        });
        return;
      case "stop":
        cleanup();
        env.exit();
        return;
      case "notice":
        // Absent is quiet; present-but-won't-open (open-failed, read-error) is
        // the loud case and logs at error. A recovering write-failed zombie is
        // a warn — it is expected around suspend and self-heals.
        env.log({
          level: effect.code === "suspend-zombie" ? "warn" : "error",
          message: `lifecycle notice: ${effect.code}`,
          cause: effect.cause,
        });
        return;
    }
  };

  // If a monitor subprocess dies (dbus restart, OOM, session change) we would
  // otherwise lose hotplug and suspend/resume forever behind a single log line.
  // Supervise each: restart with capped backoff and log the exit at error.
  const superviseSource = (
    label: string,
    start: (onEnd: (cause: unknown) => void) => LineSubscription,
  ): LineSubscription => {
    let current: LineSubscription | null = null;
    let restartTimer: unknown = null;
    let attempt = 0;
    let stopped = false;

    const spawnOnce = (): void => {
      current = start((cause) => {
        current = null;
        if (stopped) {
          return;
        }
        const delay = Math.min(MONITOR_RESTART_BASE_MS * 2 ** attempt, MONITOR_RESTART_CAP_MS);
        attempt += 1;
        env.log({ level: "error", message: `${label} monitor ended; restarting in ${delay}ms`, cause });
        restartTimer = env.setTimer(() => {
          restartTimer = null;
          spawnOnce();
        }, delay);
      });
    };

    spawnOnce();

    return {
      stop: () => {
        stopped = true;
        if (restartTimer !== null) {
          env.clearTimer(restartTimer);
          restartTimer = null;
        }
        current?.stop();
        current = null;
      },
    };
  };

  const sleepSource: LineSubscription = superviseSource("sleep", (onEnd) =>
    createSleepSource(env.spawn, {
      onSleep: () => dispatch({ type: "sleep" }),
      onWake: () => dispatch({ type: "wake" }),
      onEnd,
    }),
  );

  const udevSource: LineSubscription = superviseSource("udev", (onEnd) =>
    createUdevSource(env.spawn, {
      onAdded: () => dispatch({ type: "device-added" }),
      onRemoved: () => dispatch({ type: "device-removed" }),
      onEnd,
    }),
  );

  const cleanup = (): void => {
    stopPolling();
    cancelReopen();
    sleepSource.stop();
    udevSource.stop();
    lock.release();
  };

  env.registerSignals(() => dispatch({ type: "shutdown" }));

  if (env.devicePresentAtStart) {
    dispatch({ type: "device-added" });
  }

  return {
    stop: cleanup,
    notifyWriteFailure: (error) => dispatch({ type: "write-failed", error }),
  };
};

export type { LockHandle };

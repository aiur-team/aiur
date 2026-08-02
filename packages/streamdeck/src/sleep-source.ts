/**
 * Suspend/resume source backed by logind's `PrepareForSleep` signal.
 *
 * This is the single most-reported long-running failure across every Stream
 * Deck library (python-elgato-streamdeck #78, streamdeck-ui #155/#184,
 * companion #2795): after suspend the reader dies silently while the library's
 * `connected()` still returns true. So we do not trust `connected()`. We
 * subscribe to `org.freedesktop.login1`'s `PrepareForSleep`, close before the
 * machine sleeps, and reopen after it resumes.
 *
 * `PrepareForSleep(true)` fires *before* suspend and `PrepareForSleep(false)`
 * *after* resume, so a "sleep" line maps to the reducer's `sleep` event and a
 * "wake" line to `wake`. This D-Bus approach is inferred from those issues
 * rather than documented upstream practice; it must be verified on hardware by
 * actually suspending the machine.
 *
 * We read the signal via `gdbus monitor` rather than a native D-Bus binding to
 * stay dependency-free — see {@link file://./line-source.ts}.
 */

import { spawnLineSource, type LineSubscription, type SpawnLike } from "./line-source.js";

/** Argv that streams the login1 `PrepareForSleep` signal as text lines. */
export const SLEEP_MONITOR_COMMAND = "gdbus";
export const SLEEP_MONITOR_ARGS: readonly string[] = [
  "monitor",
  "--system",
  "--dest",
  "org.freedesktop.login1",
  "--object-path",
  "/org/freedesktop/login1",
];

export interface SleepHandlers {
  onSleep(): void;
  onWake(): void;
  onEnd?(cause: unknown): void;
}

/**
 * Parses a `gdbus monitor` line for a `PrepareForSleep` signal. Returns
 * `"sleep"` for the pre-suspend `true`, `"wake"` for the post-resume `false`,
 * and `null` for every other line (the monitor emits many).
 */
export const parsePrepareForSleep = (line: string): "sleep" | "wake" | null => {
  if (!line.includes("PrepareForSleep")) {
    return null;
  }
  const match = line.match(/\b(true|false)\b/);
  if (!match) {
    return null;
  }
  return match[1] === "true" ? "sleep" : "wake";
};

/** Starts the logind sleep/wake subscription. */
export const createSleepSource = (spawn: SpawnLike, handlers: SleepHandlers): LineSubscription =>
  spawnLineSource(spawn, SLEEP_MONITOR_COMMAND, SLEEP_MONITOR_ARGS, {
    onLine: (line) => {
      const signal = parsePrepareForSleep(line);
      if (signal === "sleep") {
        handlers.onSleep();
      } else if (signal === "wake") {
        handlers.onWake();
      }
    },
    onEnd: handlers.onEnd,
  });

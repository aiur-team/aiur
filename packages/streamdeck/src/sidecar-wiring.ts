/**
 * Stateless helpers of the process entry point. Split from `main.ts`, and
 * excluded from coverage for the same reason: wiring with nothing to decide.
 */
import { homedir } from "node:os";
import path from "node:path";
import process from "node:process";

import { debugEnabled } from "./debug.js";
import { debug } from "./hid-device.js";
import { decodeInputReport } from "./input.js";
import type { LogEntry } from "./runtime.js";

/**
 * Where the remembered microphone is kept.
 *
 * `XDG_CONFIG_HOME` when the desktop sets it, `~/.config` otherwise — the same
 * rule every other tool on this box follows, so the file lands where an
 * operator would look for it and where their dotfile backup already reaches.
 */
export const micPreferencePath = (): string =>
  path.join(process.env.XDG_CONFIG_HOME ?? path.join(homedir(), ".config"), "aiur", "streamdeck-mic.json");

/** Traces a report's decoded controls; a no-op unless debug tracing is on. */
export const traceInput = (data: Uint8Array): void => {
  if (debugEnabled(process.env.AIUR_STREAMDECK_DEBUG)) {
    const decoded = decodeInputReport(data);
    debug("input.decoded", {
      count: decoded.length,
      controls: decoded.map((input) =>
        input.type === "encoder-turn"
          ? `turn${input.index}:${input.ticks}`
          : `${input.type === "key" ? "key" : "dial"}${input.index}:${input.pressed ? "down" : "up"}`,
      ),
    });
  }
};

/** Routes a runtime log entry to the matching console level. */
export const logLine = ({ level, message, cause }: LogEntry): void => {
  const line = `[streamdeck] ${message}`;
  if (level === "error") {
    console.error(line, cause ?? "");
  } else if (level === "warn") {
    console.warn(line, cause ?? "");
  } else {
    console.info(line);
  }
};


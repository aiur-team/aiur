/**
 * Process entry point: constructs the real Node primitives and hands them to
 * the fully-tested {@link startRuntime}.
 *
 * This file is intentionally excluded from coverage (see vitest.config.ts): it
 * contains only dependency wiring — real `node:net`, `node:child_process`,
 * `node:fs`, `node:process`, and device-node discovery — with no branching
 * logic worth unit-testing in isolation. Everything it wires is covered
 * through the injected fakes in the runtime and adapter tests. The hardware
 * acceptance items (open by VID/PID, suspend/resume, unplug/replug, feature
 * reports) are verified by running this against a real Stream Deck +.
 */

import { spawn } from "node:child_process";
import { open, readFile, readdir } from "node:fs/promises";
import net from "node:net";
import process from "node:process";

import { findStreamDeckPath, parseBrightness, type DevicePathFs } from "./device-path.js";
import { openHidrawBackend } from "./hidraw-backend.js";
import { startRuntime } from "./runtime.js";

const pathFs: DevicePathFs = { readdir, readFile };

export const main = async (): Promise<void> => {
  const brightness = parseBrightness(process.env.AIUR_STREAMDECK_BRIGHTNESS);
  const initialPath = await findStreamDeckPath(pathFs);

  await startRuntime({
    spawn,
    net,
    brightness,
    devicePresentAtStart: initialPath !== null,
    openBackend: async () => {
      const path = (await findStreamDeckPath(pathFs)) ?? initialPath;
      if (path === null) {
        throw new Error("Stream Deck + not found: no matching /dev/hidraw node");
      }
      return openHidrawBackend({ open }, path);
    },
    registerSignals: (handler) => {
      process.on("SIGTERM", handler);
      process.on("SIGINT", handler);
    },
    exit: () => process.exit(0),
    setTimer: (fn, ms) => setTimeout(fn, ms),
    clearTimer: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
    log: ({ level, message, cause }) => {
      const line = `[streamdeck] ${message}`;
      if (level === "error") {
        console.error(line, cause ?? "");
      } else if (level === "warn") {
        console.warn(line, cause ?? "");
      } else {
        console.info(line);
      }
    },
  });
};

void main().catch((error) => {
  console.error("[streamdeck] fatal:", error);
  process.exitCode = 1;
});

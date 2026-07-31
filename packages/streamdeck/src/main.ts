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

import { openHidrawBackend } from "./hidraw-backend.js";
import { PRODUCT_ID, VENDOR_ID } from "./report.js";
import { startRuntime } from "./runtime.js";

/** HID_ID token udev/sysfs expose, e.g. `0003:00000FD9:00000084`. */
const hidId = (vendor: number, product: number): string =>
  `${vendor.toString(16).toUpperCase().padStart(8, "0")}:${product.toString(16).toUpperCase().padStart(8, "0")}`;

/** Scans `/sys/class/hidraw` for the Stream Deck + node, returning `/dev/hidrawN`. */
const findDevicePath = async (): Promise<string | null> => {
  const wanted = hidId(VENDOR_ID, PRODUCT_ID);
  const nodes = await readdir("/sys/class/hidraw").catch(() => [] as string[]);
  for (const node of nodes) {
    const uevent = await readFile(`/sys/class/hidraw/${node}/device/uevent`, "utf8").catch(() => "");
    if (uevent.toUpperCase().includes(wanted)) {
      return `/dev/${node}`;
    }
  }
  return null;
};

export const main = async (): Promise<void> => {
  const brightness = Number.parseInt(process.env.AIUR_STREAMDECK_BRIGHTNESS ?? "80", 10);
  const initialPath = await findDevicePath();

  await startRuntime({
    spawn,
    net,
    brightness: Number.isFinite(brightness) ? brightness : 80,
    devicePresentAtStart: initialPath !== null,
    openBackend: async () => {
      const path = (await findDevicePath()) ?? initialPath;
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

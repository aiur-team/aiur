/**
 * Hotplug source backed by udev events.
 *
 * None of the three reference libraries implement hotplug; the common
 * workaround is polling `enumerate()` on a timer, which is strictly worse — it
 * misses removes and burns cycles. We do it event-driven by tailing
 * `udevadm monitor --property` for `usb`/`hidraw` events whose vendor matches
 * `0fd9`, mapping an `add` to the reducer's `device-added` and a `remove` to
 * `device-removed`.
 *
 * `udevadm monitor --property` prints one blank-line-separated block per event:
 * a header line, then `KEY=VALUE` property lines. We buffer lines into blocks
 * and parse each complete block. Dependency-free by design — see
 * {@link file://./line-source.ts}.
 */

import { spawnLineSource, type LineSubscription, type SpawnLike } from "./line-source.js";
import { VENDOR_ID } from "./report.js";

/** Vendor ID as udev reports it: lowercase hex, no `0x`. */
const VENDOR_HEX = VENDOR_ID.toString(16).padStart(4, "0");

export const UDEV_MONITOR_COMMAND = "udevadm";
export const UDEV_MONITOR_ARGS: readonly string[] = [
  "monitor",
  "--udev",
  "--property",
  "--subsystem-match=usb",
  "--subsystem-match=hidraw",
];

export interface UdevHandlers {
  onAdded(): void;
  onRemoved(): void;
  onEnd?(cause: unknown): void;
}

/**
 * Parses one udev property block. Returns the hotplug event only when the block
 * both matches our vendor and carries an `add`/`remove` action; every other
 * block (a different device, a `change`, the initial header) is `null`.
 */
export const parseUdevBlock = (lines: readonly string[]): "device-added" | "device-removed" | null => {
  const props = new Map<string, string>();
  for (const line of lines) {
    const eq = line.indexOf("=");
    if (eq > 0) {
      props.set(line.slice(0, eq), line.slice(eq + 1));
    }
  }

  if (props.get("ID_VENDOR_ID")?.toLowerCase() !== VENDOR_HEX) {
    return null;
  }

  switch (props.get("ACTION")) {
    case "add":
      return "device-added";
    case "remove":
      return "device-removed";
    default:
      return null;
  }
};

/** Starts the udev hotplug subscription. */
export const createUdevSource = (spawn: SpawnLike, handlers: UdevHandlers): LineSubscription => {
  let block: string[] = [];

  const flush = (): void => {
    if (block.length === 0) {
      return;
    }
    const event = parseUdevBlock(block);
    block = [];
    if (event === "device-added") {
      handlers.onAdded();
    } else if (event === "device-removed") {
      handlers.onRemoved();
    }
  };

  return spawnLineSource(spawn, UDEV_MONITOR_COMMAND, UDEV_MONITOR_ARGS, {
    onLine: (line) => {
      if (line.trim() === "") {
        flush();
      } else {
        block.push(line);
      }
    },
    onEnd: handlers.onEnd,
  });
};

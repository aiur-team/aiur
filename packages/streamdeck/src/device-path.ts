/**
 * Device-node discovery and environment parsing for the process entry point.
 *
 * Split out of {@link file://./main.ts} so its real branching — scanning
 * `/sys/class/hidraw` for the Stream Deck +, and parsing the brightness env
 * var — is unit-tested rather than hidden behind main.ts's coverage exclusion.
 * The filesystem surface is injected so this never touches sysfs under test.
 */

import { PRODUCT_ID, VENDOR_ID } from "./report.js";

/** Minimal `node:fs/promises` surface device discovery needs. */
export interface DevicePathFs {
  readdir(path: string): Promise<string[]>;
  readFile(path: string, encoding: "utf8"): Promise<string>;
}

/** Default sysfs directory that lists hidraw nodes. */
export const HIDRAW_CLASS_DIR = "/sys/class/hidraw";

/** The `HID_ID` token sysfs/udev expose, e.g. `0003:00000FD9:00000084`. */
export const hidId = (vendor: number, product: number): string =>
  `${vendor.toString(16).toUpperCase().padStart(8, "0")}:${product.toString(16).toUpperCase().padStart(8, "0")}`;

/**
 * Scans the hidraw class directory for the Stream Deck + and returns its
 * `/dev/hidrawN` path, or `null` when absent. An unreadable class directory or
 * `uevent` file is treated as "not this node" rather than an error, so a
 * transient permission blip on one node does not mask the device on another.
 */
export const findStreamDeckPath = async (fs: DevicePathFs, classDir: string = HIDRAW_CLASS_DIR): Promise<string | null> => {
  const wanted = hidId(VENDOR_ID, PRODUCT_ID);
  const nodes = await fs.readdir(classDir).catch(() => [] as string[]);
  for (const node of nodes) {
    const uevent = await fs.readFile(`${classDir}/${node}/device/uevent`, "utf8").catch(() => "");
    if (uevent.toUpperCase().includes(wanted)) {
      return `/dev/${node}`;
    }
  }
  return null;
};

/**
 * Parses the brightness env var to an integer, falling back to `fallback`
 * (default 80) when unset or non-numeric.
 */
export const parseBrightness = (raw: string | undefined, fallback = 80): number => {
  const value = Number.parseInt(raw ?? "", 10);
  return Number.isFinite(value) ? value : fallback;
};

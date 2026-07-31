/**
 * Transport backend interface: the narrow HID surface the lifecycle needs.
 *
 * Two backends are possible and the choice is a hardware fact #1342 could not
 * resolve (its probe never opened the device node):
 *
 * - **hidraw over `node:fs`** — the dependency-free default. It can issue
 *   OUTPUT reports (the 1024-byte key-stream reset, image chunks) and read
 *   INPUT reports, but it *cannot* send/receive FEATURE reports: those require
 *   the `HIDIOCSFEATURE`/`HIDIOCGFEATURE` ioctls, which Node's `fs` cannot
 *   perform. Brightness, Show Logo (reset), serial, and firmware are all
 *   feature reports. See {@link file://./hidraw-backend.ts}.
 * - **libusb / node-hid** — required to issue those feature reports. If the
 *   feature-report path is needed on a given host, use a libusb-backed handle;
 *   this interface is the same either way, so only the constructor changes.
 *
 * Byte convention: every buffer keeps the report ID at byte 0 in both
 * directions — see {@link file://./report.ts}.
 */

import type { RawRead } from "./read.js";

export interface HidBackend {
  /** Sends one OUTPUT report (report ID at byte 0). */
  write(report: Uint8Array): Promise<void>;
  /** Polls once for an INPUT report; resolves timeout when none is pending. */
  read(): Promise<RawRead>;
  /** Sends one FEATURE report (brightness, reset/Show Logo). */
  sendFeatureReport(report: Uint8Array): Promise<void>;
  /** Reads one FEATURE report (serial, firmware) by ID. */
  getFeatureReport(reportId: number, length: number): Promise<Uint8Array>;
  /** Releases the handle. Teardown errors are normal on unplug. */
  close(): Promise<void>;
}

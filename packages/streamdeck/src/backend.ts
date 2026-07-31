/**
 * Transport backend interface: the narrow HID surface the lifecycle needs.
 *
 * Two backends implement this interface; the choice turns on a hardware fact
 * #1342 could not resolve (its probe never opened the device node):
 *
 * - **libusb — the shipped default** ({@link file://./usb-backend.ts}). It moves
 *   OUTPUT and INPUT reports over the interrupt endpoints *and* issues FEATURE
 *   reports as class control transfers, so brightness, Show Logo (reset),
 *   serial, and firmware all work. #1354's acceptance requires those, so this
 *   is what {@link file://./main.ts} wires.
 * - **hidraw over `node:fs`** — the dependency-free alternative
 *   ({@link file://./hidraw-backend.ts}). It can issue OUTPUT reports (the
 *   1024-byte key-stream reset, image chunks) and read INPUT reports, but it
 *   *cannot* send/receive FEATURE reports: those require the
 *   `HIDIOCSFEATURE`/`HIDIOCGFEATURE` ioctls, which Node's `fs` cannot perform.
 *   Usable only on a host that never needs a feature report.
 *
 * The interface is identical either way, so selecting a backend is a single
 * constructor swap in main.ts.
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

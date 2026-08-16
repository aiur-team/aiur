/**
 * libusb transport backend.
 *
 * The hidraw/`node:fs` backend ({@link file://./hidraw-backend.ts}) can move
 * OUTPUT and INPUT reports but **cannot** issue FEATURE reports — those need
 * the `HIDIOCSFEATURE`/`HIDIOCGFEATURE` ioctls, which `node:fs` cannot perform.
 * Brightness, Show Logo/reset, serial, and firmware are all feature reports, so
 * a hidraw-only sidecar leaves the deck frozen on the last frame at shutdown and
 * never applies brightness. #1354's acceptance is explicit: those must work, and
 * "if it cannot, use libusb". This is that libusb path.
 *
 * A feature report over USB is a class control transfer on the interface:
 *
 * - **SET_REPORT** — `bmRequestType 0x21`, `bRequest 0x09`, `wValue`
 *   `(0x03 << 8) | reportId` (0x03 = Feature), `wIndex` = interface number,
 *   data = the full report.
 * - **GET_REPORT** — `bmRequestType 0xA1`, `bRequest 0x01`, same `wValue`,
 *   returning the report.
 *
 * OUTPUT reports (the 1024-byte key-stream reset, image chunks) go out the
 * interrupt OUT endpoint; INPUT reports (dial/touch events) come in the
 * interrupt IN endpoint, whose per-poll timeout is reported as
 * {@link RawRead} `timeout` — never an error, never a disconnect
 * ({@link file://./read.ts}), so there is no phantom reconnect loop.
 *
 * Because libusb claims the interface (detaching the kernel hidraw driver), this
 * is a *single* owner of the device: do not also open the hidraw node. The
 * advisory lock ({@link file://./lock.ts}) still guards against a second process.
 *
 * Byte convention: every buffer keeps the report ID at byte 0 in both
 * directions — see {@link file://./report.ts}. The report ID is therefore both
 * the low byte of `wValue` and the first data byte, matching hidapi.
 *
 * The device object is injected ({@link UsbDeviceLike}) so this is testable
 * against a fake and never claims real hardware under test; {@link file://./main.ts}
 * adapts the real `usb` package to it.
 */

import type { HidBackend } from "./backend.js";
import type { RawRead } from "./read.js";
import { INPUT_REPORT_LENGTH } from "./report.js";

/** Result of a single interrupt-IN poll. */
export type UsbInResult = { timedOut: true } | { timedOut: false; data: Uint8Array };

/**
 * Minimal claimed-USB-device surface the backend uses. All methods act on the
 * already-selected HID interface; the adapter in main.ts binds the interface
 * number and endpoints.
 */
export interface UsbDeviceLike {
  /** Claims the HID interface (detaching the kernel driver if needed). */
  claim(): Promise<void>;
  /** Issues a control-OUT transfer (SET_REPORT). */
  controlOut(bmRequestType: number, bRequest: number, wValue: number, wIndex: number, data: Uint8Array): Promise<void>;
  /** Issues a control-IN transfer (GET_REPORT) and resolves the returned bytes. */
  controlIn(bmRequestType: number, bRequest: number, wValue: number, wIndex: number, length: number): Promise<Uint8Array>;
  /** Sends one OUTPUT report on the interrupt-OUT endpoint. */
  transferOut(data: Uint8Array): Promise<void>;
  /**
   * Polls the interrupt-IN endpoint once. Resolves `{ timedOut: true }` when no
   * report arrives within the poll window; rejects only on a genuine failure.
   */
  transferIn(length: number): Promise<UsbInResult>;
  /** Releases the interface and closes the handle. */
  close(): Promise<void>;
}

/** USB HID class-request constants (see the module header). */
const HID_SET_REPORT = 0x09;
const HID_GET_REPORT = 0x01;
const REQTYPE_CLASS_INTERFACE_OUT = 0x21;
const REQTYPE_CLASS_INTERFACE_IN = 0xa1;
/** Report type nibble for a Feature report, in the high byte of `wValue`. */
const HID_REPORT_TYPE_FEATURE = 0x03;

/** `wValue` for a feature-report control transfer: type in the high byte, ID in the low. */
const featureValue = (reportId: number): number => (HID_REPORT_TYPE_FEATURE << 8) | (reportId & 0xff);

export interface UsbBackendOptions {
  /** HID interface number the control transfers target (default 0). */
  interfaceNumber?: number;
}

/**
 * Claims the interface and returns a {@link HidBackend} bound to `device`.
 * Rejects if the interface cannot be claimed, which surfaces as a clear error
 * to the caller (missing permission, device gone).
 */
export const openUsbBackend = async (device: UsbDeviceLike, options: UsbBackendOptions = {}): Promise<HidBackend> => {
  const wIndex = options.interfaceNumber ?? 0;
  await device.claim();

  return {
    write: (report) => device.transferOut(report),

    read: async (): Promise<RawRead> => {
      try {
        const result = await device.transferIn(INPUT_REPORT_LENGTH);
        if (result.timedOut) {
          return { kind: "timeout" };
        }
        return { kind: "bytes", data: result.data };
      } catch (error) {
        return { kind: "error", error };
      }
    },

    sendFeatureReport: (report) =>
      device.controlOut(REQTYPE_CLASS_INTERFACE_OUT, HID_SET_REPORT, featureValue(report[0] ?? 0), wIndex, report),

    // NOTE: unlike hidapi, a raw USB GET_REPORT returns exactly the bytes the
    // device sends for this `wValue`; whether the leading byte is the report ID
    // is device-dependent. The consumer (#1355, serial/firmware) must confirm
    // the byte-0 offset against real hardware and size `length` accordingly.
    getFeatureReport: (reportId, length) =>
      device.controlIn(REQTYPE_CLASS_INTERFACE_IN, HID_GET_REPORT, featureValue(reportId), wIndex, length),

    close: () => device.close(),
  };
};

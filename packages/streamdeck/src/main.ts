/**
 * Process entry point: constructs the real Node primitives and the real libusb
 * device, then hands them to the fully-tested {@link startRuntime}.
 *
 * This file is intentionally excluded from coverage (see vitest.config.ts): it
 * contains only dependency wiring — real `node:net`, `node:child_process`,
 * `node:process`, and the `usb` package adapted to the tested
 * {@link UsbDeviceLike} surface — with no branching logic worth unit-testing in
 * isolation. Everything it wires is covered through the injected fakes in the
 * runtime, backend, and adapter tests. The hardware acceptance items (open by
 * VID/PID, suspend/resume, unplug/replug, feature reports) are verified by
 * running this against a real Stream Deck +.
 *
 * **Backend: libusb.** #1354's acceptance requires brightness, reset/Show Logo,
 * serial, and firmware — all FEATURE reports — to work, and the hidraw/`node:fs`
 * backend cannot issue feature reports (no ioctls). Per the ticket, "if it
 * cannot, use libusb": this wires the {@link file://./usb-backend.ts} backend,
 * which claims the interface and speaks OUTPUT/INPUT reports over the interrupt
 * endpoints and FEATURE reports over control transfers. `usb` ships N-API
 * prebuilt binaries, so it needs no native toolchain at install time.
 */

import { spawn } from "node:child_process";
import net from "node:net";
import process from "node:process";

import { findByIds, InEndpoint, LibUSBException, OutEndpoint, usb } from "usb";

import { parseBrightness } from "./device-path.js";
import { POLL_INTERVAL_MS, PRODUCT_ID, VENDOR_ID } from "./report.js";
import { startRuntime } from "./runtime.js";
import { openUsbBackend, type UsbDeviceLike } from "./usb-backend.js";

/** HID interface number on the Stream Deck +. */
const HID_INTERFACE = 0;
/** Timeout for feature-report control transfers. */
const CONTROL_TIMEOUT_MS = 1000;

/** True when a matching Stream Deck + is present on the USB bus right now. */
const deviceIsPresent = (): boolean => findByIds(VENDOR_ID, PRODUCT_ID) !== undefined;

/**
 * Opens the Stream Deck + over libusb and adapts it to {@link UsbDeviceLike}.
 * Wraps the callback-based `usb` primitives as promises and maps a libusb
 * timeout on the interrupt-IN endpoint to a poll `timeout` rather than an error.
 */
const openStreamDeckDevice = async (): Promise<UsbDeviceLike> => {
  const device = findByIds(VENDOR_ID, PRODUCT_ID);
  if (device === undefined) {
    throw new Error("Stream Deck + not found: no USB device with VID 0x0fd9 / PID 0x0084");
  }

  device.open();
  device.timeout = CONTROL_TIMEOUT_MS;
  device.setAutoDetachKernelDriver(true);

  const iface = device.interface(HID_INTERFACE);
  const inEndpoint = iface.endpoints.find((endpoint): endpoint is InEndpoint => endpoint.direction === "in");
  const outEndpoint = iface.endpoints.find((endpoint): endpoint is OutEndpoint => endpoint.direction === "out");
  if (inEndpoint === undefined || outEndpoint === undefined) {
    device.close();
    throw new Error("Stream Deck + interface is missing an interrupt endpoint");
  }
  // A read timeout means "no event pending", so bound the poll to the interval.
  inEndpoint.timeout = POLL_INTERVAL_MS;

  return {
    claim: async () => {
      iface.claim();
    },
    controlOut: (bmRequestType, bRequest, wValue, wIndex, data) =>
      new Promise<void>((resolve, reject) => {
        device.controlTransfer(bmRequestType, bRequest, wValue, wIndex, Buffer.from(data), (error) =>
          error ? reject(error) : resolve(),
        );
      }),
    controlIn: (bmRequestType, bRequest, wValue, wIndex, length) =>
      new Promise((resolve, reject) => {
        device.controlTransfer(bmRequestType, bRequest, wValue, wIndex, length, (error, buffer) =>
          error ? reject(error) : resolve(Uint8Array.from(buffer as Buffer)),
        );
      }),
    transferOut: (data) =>
      new Promise<void>((resolve, reject) => {
        outEndpoint.transfer(Buffer.from(data), (error?: LibUSBException) => (error ? reject(error) : resolve()));
      }),
    transferIn: (length) =>
      new Promise((resolve, reject) => {
        inEndpoint.transfer(length, (error: LibUSBException | undefined, data?: Buffer) => {
          if (error) {
            if (error.errno === usb.LIBUSB_ERROR_TIMEOUT) {
              resolve({ timedOut: true });
              return;
            }
            reject(error);
            return;
          }
          resolve({ timedOut: false, data: Uint8Array.from(data ?? Buffer.alloc(0)) });
        });
      }),
    close: async () => {
      await new Promise<void>((resolve) => iface.release(true, () => resolve()));
      device.close();
    },
  };
};

export const main = async (): Promise<void> => {
  const brightness = parseBrightness(process.env.AIUR_STREAMDECK_BRIGHTNESS);

  await startRuntime({
    spawn,
    net,
    brightness,
    devicePresentAtStart: deviceIsPresent(),
    openBackend: async () => openUsbBackend(await openStreamDeckDevice(), { interfaceNumber: HID_INTERFACE }),
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

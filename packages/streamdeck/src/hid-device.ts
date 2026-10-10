/**
 * The real libusb Stream Deck +: device discovery, open, and the input report
 * buffer. Split from `main.ts`, and excluded from coverage for the same reason:
 * it only adapts the `usb` package to the tested {@link UsbDeviceLike} surface.
 */
import process from "node:process";

import { findByIds, InEndpoint, type Interface, LibUSBException, OutEndpoint } from "usb";
import { createDebugLog, debugEnabled, hexPreview } from "./debug.js";
import { INPUT_REPORT_LENGTH, POLL_INTERVAL_MS, PRODUCT_ID, VENDOR_ID } from "./report.js";
import { type UsbDeviceLike, type UsbInResult } from "./usb-backend.js";

/** HID interface number on the Stream Deck +. */
export const HID_INTERFACE = 0;
/** Timeout for feature-report control transfers. */
const CONTROL_TIMEOUT_MS = 1000;
/**
 * Interrupt-IN transfers node-usb keeps queued in the kernel. Several in flight
 * means a burst of events (a dial spun quickly, a key chord) is buffered by the
 * kernel rather than dropped between reads.
 */
const POLL_TRANSFER_COUNT = 3;
/**
 * Cap on input reports buffered between reads. Deep enough to absorb a burst
 * (a key chord, a fast dial spin) without dropping anything an operator would
 * notice, shallow enough that a runaway stream cannot grow memory unbounded.
 */
const MAX_BUFFERED_REPORTS = 64;

/** Tracer for the paths that otherwise produce no operator-visible output. */
export const debug = createDebugLog(debugEnabled(process.env.AIUR_STREAMDECK_DEBUG));

/** True when a matching Stream Deck + is present on the USB bus right now. */
export const deviceIsPresent = (): boolean => findByIds(VENDOR_ID, PRODUCT_ID) !== undefined;

/**
 * Opens the Stream Deck + over libusb and adapts it to {@link UsbDeviceLike}.
 * Wraps the callback-based `usb` primitives as promises and reports an idle
 * input interval as a poll `timeout` rather than an error.
 *
 * **Input is a push stream, not a pull.** node-usb's one-shot
 * `InEndpoint.transfer()` never invokes its callback on this device — verified
 * against real hardware, it does not fire even after `endpoint.timeout`
 * elapses — so a read loop built on it submits one transfer and then stalls
 * forever. `startPoll` is the supported streaming API: it keeps several
 * correctly-sized transfers queued in the kernel and emits `data` as reports
 * arrive. This adapter buffers those reports and hands them to the runtime's
 * pull-shaped `read()`, synthesising the idle `timeout` with a Node timer, so
 * the tested lifecycle contract in {@link file://./runtime.ts} is unchanged.
 */
export const openStreamDeckDevice = async (): Promise<UsbDeviceLike> => {
  const device = findByIds(VENDOR_ID, PRODUCT_ID);
  if (device === undefined) {
    throw new Error("Stream Deck + not found: no USB device with VID 0x0fd9 / PID 0x0084");
  }

  device.open();
  // Everything after open() must close the handle on failure, or a leaked open
  // handle makes the next reconnect attempt fail with LIBUSB_ERROR_BUSY — a
  // self-inflicted "present but won't open" that would trip the operator alert.
  let inEndpoint: InEndpoint;
  let outEndpoint: OutEndpoint;
  let iface: Interface;
  try {
    device.timeout = CONTROL_TIMEOUT_MS;
    device.setAutoDetachKernelDriver(true);

    iface = device.interface(HID_INTERFACE);
    const foundIn = iface.endpoints.find((endpoint): endpoint is InEndpoint => endpoint.direction === "in");
    const foundOut = iface.endpoints.find((endpoint): endpoint is OutEndpoint => endpoint.direction === "out");
    if (foundIn === undefined || foundOut === undefined) {
      throw new Error("Stream Deck + interface is missing an interrupt endpoint");
    }
    inEndpoint = foundIn;
    outEndpoint = foundOut;
    // Bulk OUT (the 1024-byte key-stream reset, image chunks) can legitimately
    // take longer than the control timeout; use no timeout so a slow-but-healthy
    // write is not misread as a failure.
    outEndpoint.timeout = 0;
  } catch (error) {
    device.close();
    throw error;
  }

  debug("device.open", {
    inMaxPacket: inEndpoint.descriptor.wMaxPacketSize,
    requesting: INPUT_REPORT_LENGTH,
  });

  // Reports delivered by the poll stream but not yet claimed by a read().
  const inbox: Uint8Array[] = [];
  let pending: ((result: UsbInResult) => void) | null = null;
  // A stream error stops node-usb's polling, so latch it and fail the next
  // read: that is what drives the runtime's close/reopen recovery.
  let streamError: unknown = null;
  let polling = false;

  const deliver = (data: Uint8Array): void => {
    debug("input.report", { length: data.length, bytes: hexPreview(data) });
    const waiter = pending;
    if (waiter !== null) {
      pending = null;
      waiter({ timedOut: false, data });
      return;
    }
    // Bound the backlog. A dial spun hard produces reports faster than the
    // reader drains them, and an unbounded queue would both grow without limit
    // and replay stale motion long after the operator stopped.
    if (inbox.length >= MAX_BUFFERED_REPORTS) {
      inbox.shift();
    }
    inbox.push(data);
  };

  const startInput = (): void => {
    if (polling) return;
    polling = true;
    inEndpoint.on("data", (data: Buffer) => deliver(Uint8Array.from(data)));
    inEndpoint.on("error", (error: unknown) => {
      debug("input.streamError", { error: String(error) });
      streamError = error;
      polling = false;
      // Wake a waiter immediately instead of letting it idle out, so the
      // runtime starts its close/reopen a poll interval sooner.
      releaseWaiter();
    });
    inEndpoint.startPoll(POLL_TRANSFER_COUNT, INPUT_REPORT_LENGTH);
    debug("input.pollStarted", { transfers: POLL_TRANSFER_COUNT, size: INPUT_REPORT_LENGTH });
  };

  /** Settles any waiter so a close does not leave a read hanging on a timer. */
  const releaseWaiter = (): void => {
    const waiter = pending;
    if (waiter !== null) {
      pending = null;
      waiter({ timedOut: true });
    }
  };

  return {
    claim: async () => {
      // `claim()` throws on BUSY/ACCESS — a second sidecar, or a udev ACL that
      // has not landed yet. That happens after this factory has returned, so
      // nothing else would close the handle, and each retry would open another
      // one while the process itself kept the device busy.
      try {
        iface.claim();
      } catch (error) {
        device.close();
        throw error;
      }
      startInput();
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
    transferIn: () =>
      new Promise((resolve, reject) => {
        // Drain buffered reports before surfacing a stream error: reports that
        // arrived before the failure are real input the operator performed, and
        // failing first would discard them along with the rest of the inbox.
        const buffered = inbox.shift();
        if (buffered !== undefined) {
          resolve({ timedOut: false, data: buffered });
          return;
        }
        if (streamError !== null) {
          const error = streamError;
          streamError = null;
          reject(error);
          return;
        }
        // Nothing queued: report an idle interval so the runtime's poll loop
        // keeps ticking instead of blocking on an event that may never come.
        // Declared before `settle`, which clears it, and assigned after —
        // so it cannot be a const even though it is only written once.
        // eslint-disable-next-line prefer-const
        let timer: ReturnType<typeof setTimeout>;
        const settle = (result: UsbInResult): void => {
          clearTimeout(timer);
          pending = null;
          resolve(result);
        };
        timer = setTimeout(() => settle({ timedOut: true }), POLL_INTERVAL_MS);
        pending = settle;
      }),
    close: async () => {
      polling = false;
      releaseWaiter();
      // Do NOT call stopPoll() here. `iface.release(true, cb)` already cancels
      // the poll and waits for the endpoint's `end` event before releasing;
      // stopping it first clears `pollActive`, so release skips that wait and
      // `device.close()` runs while cancelled transfers still hold device refs
      // — which throws "Can't close device with a pending request" and leaks
      // the handle on every reconnect.
      await new Promise<void>((resolve) => iface.release(true, () => resolve()));
      inEndpoint.removeAllListeners();
      device.close();
    },
  };
};


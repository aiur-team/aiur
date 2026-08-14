/**
 * Hardware input probe for the Stream Deck +.
 *
 * Diagnostic only — not shipped in the package archive. It opens the deck over
 * libusb the way `main.ts` does and reads the interrupt-IN endpoint, logging
 * every outcome with its byte length and a hex prefix. Use it when the deck
 * stops responding to keys or dials and you need to know whether reports are
 * reaching the host at all.
 *
 * It exists because two transport facts are invisible from the application
 * layer and cost a long debugging session to establish:
 *
 *   1. node-usb's one-shot `InEndpoint.transfer()` never calls back on this
 *      device — not even when `endpoint.timeout` elapses — so a read loop built
 *      on it stalls after its first read. `startPoll` is the working API.
 *   2. The device's HID report descriptor declares input report 1 as 511 data
 *      bytes plus the report ID (512 total). Requesting fewer fails the
 *      transfer with `LIBUSB_ERROR_OVERFLOW` rather than truncating.
 *
 * Usage:
 *   node scripts/probe-input.mjs [requestLength] [mode]
 *
 * `requestLength` defaults to 512; pass 14 to reproduce the overflow. `mode` is
 * `poll` (default, the streaming API the sidecar uses) or `transfer` (the
 * one-shot API, to demonstrate the stall). Stop the sidecar first — libusb
 * claims the interface exclusively:
 *
 *   systemctl --user stop aiur-streamdeck.service
 */
import { findByIds, usb } from "usb";

const VENDOR_ID = 0x0fd9;
const PRODUCT_ID = 0x0084;
const HID_INTERFACE = 0;
const TRANSFER_TIMEOUT_MS = 1000;
const POLL_TRANSFER_COUNT = 3;

const requestLength = Number.parseInt(process.argv[2] ?? "512", 10);
const mode = process.argv[3] ?? "poll";

const stamp = () => new Date().toISOString();
const hex = (bytes, limit = 24) =>
  Array.from(bytes.subarray(0, limit))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join(" ");
const errorName = (error) =>
  error.errno === usb.LIBUSB_ERROR_TIMEOUT
    ? "LIBUSB_ERROR_TIMEOUT"
    : error.errno === usb.LIBUSB_ERROR_OVERFLOW
      ? "LIBUSB_ERROR_OVERFLOW"
      : `${error.message}`;

const device = findByIds(VENDOR_ID, PRODUCT_ID);
if (device === undefined) {
  console.error("no Stream Deck + found (VID 0x0fd9 / PID 0x0084)");
  process.exit(1);
}

device.open();
device.setAutoDetachKernelDriver(true);
const iface = device.interface(HID_INTERFACE);
iface.claim();

const inEndpoint = iface.endpoints.find((endpoint) => endpoint.direction === "in");
inEndpoint.timeout = TRANSFER_TIMEOUT_MS;

console.log(
  `${stamp()} probe start: mode=${mode} requestLength=${requestLength} ` +
    `endpointMaxPacket=${inEndpoint.descriptor.wMaxPacketSize} timeout=${TRANSFER_TIMEOUT_MS}ms`,
);
console.log(`${stamp()} press keys / turn dials / touch the strip now`);

let reports = 0;
let timeouts = 0;
let errors = 0;
let running = true;

const onReport = (data) => {
  reports += 1;
  console.log(`${stamp()} REPORT length=${data.length} bytes=[${hex(data)}]`);
};

const onError = (error) => {
  if (error.errno === usb.LIBUSB_ERROR_TIMEOUT) {
    timeouts += 1;
    console.log(`${stamp()} timeout #${timeouts} (transfer returned, loop alive)`);
    return;
  }
  errors += 1;
  console.log(`${stamp()} READ ERROR errno=${error.errno} name=${errorName(error)}`);
};

if (mode === "poll") {
  inEndpoint.on("data", onReport);
  inEndpoint.on("error", onError);
  inEndpoint.startPoll(POLL_TRANSFER_COUNT, requestLength);
} else {
  const next = () => {
    if (!running) return;
    inEndpoint.transfer(requestLength, (error, data) => {
      if (error) onError(error);
      else onReport(data);
      setImmediate(next);
    });
  };
  next();
}

const shutdown = () => {
  running = false;
  console.log(`${stamp()} probe stop: reports=${reports} timeouts=${timeouts} errors=${errors}`);
  // Exit without releasing: node-usb throws "Can't close device with a pending
  // request" while a transfer is still queued, and the kernel reclaims on exit.
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

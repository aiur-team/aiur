/**
 * Device facts and HID report builders for the Elgato Stream Deck +.
 *
 * ## Report-ID byte convention
 *
 * hidapi's write and feature-report calls expect the report ID at **byte 0**,
 * and reads return it at **byte 0**. Libraries disagree on whether they keep
 * or strip that byte (the Rust crate keeps it, the node binding strips it), so
 * the same wire bytes read one offset apart depending on the library. That is
 * the most common source of off-by-one bugs in this layer.
 *
 * **This sidecar keeps the report ID at byte 0 on every buffer, both
 * directions.** An input report is therefore {@link INPUT_REPORT_LENGTH} bytes
 * with the report ID at `payload[0]` and the event body starting at
 * `payload[1]`. Every
 * output and feature report we build below places its report ID at index 0 and
 * the caller passes the whole buffer, ID included, to the backend. Backends
 * that strip the ID must re-add it; ours ({@link file://./hidraw-backend.ts})
 * does not strip.
 *
 * All builders here are pure: they allocate and fill a buffer and never touch
 * a device.
 */

/** USB vendor ID for all Elgato Stream Deck hardware. */
export const VENDOR_ID = 0x0fd9;

/** USB product ID for the Stream Deck + specifically. */
export const PRODUCT_ID = 0x0084;

/**
 * Input report length including the report ID at byte 0, and therefore the
 * exact host buffer size an interrupt-IN read must request.
 *
 * This is 512, not 14. Elgato's HID docs describe a 14-byte *meaningful*
 * payload, but the device's own HID report descriptor declares input report
 * `0x01` as Report Size 8 x Report Count 511, plus the report ID — a 512-byte
 * report, matching the interrupt-IN endpoint's `wMaxPacketSize` of 512. The
 * device pads every event out to that length.
 *
 * Requesting fewer bytes than the device sends is not a harmless truncation:
 * libusb fails the transfer with `LIBUSB_ERROR_OVERFLOW`, so a short request
 * turns every key press and dial turn into a read error instead of an input
 * event. Read the full report and let {@link file://./input.ts} decode the
 * leading bytes it cares about.
 */
export const INPUT_REPORT_LENGTH = 512;

/**
 * Smallest input report {@link file://./input.ts} can decode: report ID,
 * command, and enough body for the first control byte. Anything shorter is a
 * runt the kernel handed back for an interval with no pending event, and is
 * classified idle rather than dropped as malformed.
 */
export const MIN_INPUT_REPORT_LENGTH = 5;

/**
 * Recommended input polling interval in milliseconds. A read that returns no
 * bytes within this window is an idle poll, not a disconnect — see
 * {@link file://./read.ts}.
 */
export const POLL_INTERVAL_MS = 50;

/**
 * Length of the key-stream reset output report. The report is a full 1024-byte
 * buffer whose only non-zero byte is the leading `0x02`.
 */
export const KEY_STREAM_RESET_LENGTH = 1024;

/** Output report ID that begins a fresh image sequence. */
const KEY_STREAM_RESET_REPORT_ID = 0x02;

/** Feature report IDs Elgato documents for the Stream Deck +. */
export const FEATURE_REPORT = {
  /** `Set Brightness` feature report. */
  brightness: 0x03,
  /** `Reset` / `Show Logo` feature report. */
  reset: 0x03,
  /** `Get Firmware Version` feature report. */
  firmware: 0x05,
  /** `Get Serial Number` feature report. */
  serial: 0x06,
} as const;

/**
 * Builds the key-stream reset report: a full {@link KEY_STREAM_RESET_LENGTH}
 * buffer that is only `payload[0] = 0x02`, the rest zero. Sending it aborts any
 * partial multi-chunk image transfer before a fresh image sequence begins.
 */
export const keyStreamReset = (): Uint8Array => {
  const report = new Uint8Array(KEY_STREAM_RESET_LENGTH);
  report[0] = KEY_STREAM_RESET_REPORT_ID;
  return report;
};

/** Feature-report payload length Elgato uses for the Plus command reports. */
const FEATURE_LENGTH = 32;

/**
 * Builds the `Show Logo` reset feature report (`0x03 0x02`). Elgato recommends
 * sending it before closing the connection; skipping it leaves the deck frozen
 * on the last painted frame after exit.
 */
export const showLogo = (): Uint8Array => featureReport(FEATURE_REPORT.reset, [0x02]);

/**
 * Builds the `Set Brightness` feature report (`0x03 0x08 <percent>`). `percent`
 * is clamped to 0–100.
 */
export const setBrightness = (percent: number): Uint8Array => {
  const clamped = Math.max(0, Math.min(100, Math.trunc(percent)));
  return featureReport(FEATURE_REPORT.brightness, [0x08, clamped]);
};

/**
 * Assembles a feature report: report ID at byte 0, the given body bytes after
 * it, zero-padded to {@link FEATURE_LENGTH}.
 */
const featureReport = (reportId: number, body: readonly number[]): Uint8Array => {
  const report = new Uint8Array(FEATURE_LENGTH);
  report[0] = reportId;
  body.forEach((byte, index) => {
    report[index + 1] = byte;
  });
  return report;
};

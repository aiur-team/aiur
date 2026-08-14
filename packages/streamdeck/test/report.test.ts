import { describe, expect, it } from "vitest";

import {
  FEATURE_REPORT,
  INPUT_REPORT_LENGTH,
  KEY_STREAM_RESET_LENGTH,
  MIN_INPUT_REPORT_LENGTH,
  POLL_INTERVAL_MS,
  PRODUCT_ID,
  VENDOR_ID,
  keyStreamReset,
  setBrightness,
  showLogo,
} from "../src/report.js";

describe("device facts", () => {
  it("matches the published Stream Deck + identifiers", () => {
    expect(VENDOR_ID).toBe(0x0fd9);
    expect(PRODUCT_ID).toBe(0x0084);
    expect(POLL_INTERVAL_MS).toBe(50);
  });

  // Read from the device's own HID report descriptor: input report 0x01 is
  // Report Size 8 x Report Count 511 plus the report ID, and the interrupt-IN
  // endpoint's wMaxPacketSize is 512. Requesting the 14 bytes Elgato's docs
  // describe as the meaningful payload makes libusb fail every transfer with
  // LIBUSB_ERROR_OVERFLOW, which is why no key press ever reached the app.
  it("requests the full 512-byte input report the device actually sends", () => {
    expect(INPUT_REPORT_LENGTH).toBe(512);
    expect(MIN_INPUT_REPORT_LENGTH).toBeLessThan(INPUT_REPORT_LENGTH);
  });
});

describe("keyStreamReset", () => {
  it("is a 1024-byte report that is only payload[0] = 0x02", () => {
    const report = keyStreamReset();
    expect(report).toHaveLength(KEY_STREAM_RESET_LENGTH);
    expect(report[0]).toBe(0x02);
    expect(report.subarray(1).every((byte) => byte === 0)).toBe(true);
  });
});

describe("showLogo", () => {
  it("keeps the reset report ID at byte 0 with body 0x02", () => {
    const report = showLogo();
    expect(report[0]).toBe(FEATURE_REPORT.reset);
    expect(report[1]).toBe(0x02);
    expect(report.subarray(2).every((byte) => byte === 0)).toBe(true);
  });
});

describe("setBrightness", () => {
  it("encodes the brightness feature report", () => {
    const report = setBrightness(60);
    expect(report[0]).toBe(FEATURE_REPORT.brightness);
    expect(report[1]).toBe(0x08);
    expect(report[2]).toBe(60);
  });

  it("clamps and truncates out-of-range values", () => {
    expect(setBrightness(250)[2]).toBe(100);
    expect(setBrightness(-5)[2]).toBe(0);
    expect(setBrightness(42.9)[2]).toBe(42);
  });
});

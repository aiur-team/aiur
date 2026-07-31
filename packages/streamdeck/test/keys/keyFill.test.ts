import { describe, expect, it } from "vitest";

import {
  BLACK,
  DEFAULT_FILL_INDEX_BASE,
  KEY_FILL_COMMAND,
  KEY_FILL_REPORT_ID,
  KEY_FILL_REPORT_LENGTH,
  buildKeyFillReport,
  fillDeviceIndex,
} from "../../src/keys/keyFill.js";

describe("RGB key fill fast path (0x03 0x06)", () => {
  it("exposes the spec constants and default base", () => {
    expect(KEY_FILL_REPORT_LENGTH).toBe(32);
    expect(KEY_FILL_REPORT_ID).toBe(0x03);
    expect(KEY_FILL_COMMAND).toBe(0x06);
    expect(DEFAULT_FILL_INDEX_BASE).toBe("raw");
    expect(BLACK).toEqual({ r: 0, g: 0, b: 0 });
  });

  it("builds a 32-byte report with the raw index by default", () => {
    const report = buildKeyFillReport(2, { r: 10, g: 20, b: 30 });
    expect(report).toHaveLength(32);
    expect(report.readUInt8(0)).toBe(0x03);
    expect(report.readUInt8(1)).toBe(0x06);
    expect(report.readUInt8(2)).toBe(2); // raw index
    expect(report.readUInt8(3)).toBe(10);
    expect(report.readUInt8(4)).toBe(20);
    expect(report.readUInt8(5)).toBe(30);
    expect(report.readUInt8(6)).toBe(0); // padding
  });

  it("offsets the index by key count under the Rust convention", () => {
    expect(fillDeviceIndex(0, "raw")).toBe(0);
    expect(fillDeviceIndex(0, "key-count-offset")).toBe(8);
    expect(fillDeviceIndex(3, "key-count-offset")).toBe(11);
    const report = buildKeyFillReport(3, BLACK, "key-count-offset");
    expect(report.readUInt8(2)).toBe(11);
  });

  it("validates the key index and each channel", () => {
    expect(() => buildKeyFillReport(8, BLACK)).toThrow(RangeError);
    expect(() => buildKeyFillReport(0, { r: -1, g: 0, b: 0 })).toThrow(RangeError);
    expect(() => buildKeyFillReport(0, { r: 0, g: 256, b: 0 })).toThrow(RangeError);
    expect(() => buildKeyFillReport(0, { r: 0, g: 0, b: 1.5 })).toThrow(RangeError);
  });
});

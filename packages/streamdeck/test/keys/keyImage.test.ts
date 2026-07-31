import { describe, expect, it } from "vitest";

import {
  KEY_COMMAND_SET_IMAGE,
  KEY_COUNT,
  KEY_HEADER_LENGTH,
  KEY_IMAGE_SIZE,
  KEY_MAX_PAYLOAD,
  KEY_REPORT_ID,
  KEY_REPORT_LENGTH,
  assertKeyIndex,
  buildKeyImageReports,
} from "../../src/keys/keyImage.js";

describe("key image chunking (0x07)", () => {
  it("exposes the spec constants", () => {
    expect(KEY_REPORT_LENGTH).toBe(1024);
    expect(KEY_HEADER_LENGTH).toBe(8);
    expect(KEY_MAX_PAYLOAD).toBe(1016);
    expect(KEY_REPORT_ID).toBe(0x02);
    expect(KEY_COMMAND_SET_IMAGE).toBe(0x07);
    expect(KEY_COUNT).toBe(8);
    expect(KEY_IMAGE_SIZE).toBe(120);
  });

  it("encodes a single-chunk image with the exact header", () => {
    const jpeg = new Uint8Array([1, 2, 3, 4, 5]);
    const [report, ...rest] = buildKeyImageReports(3, jpeg);
    expect(rest).toHaveLength(0);
    expect(report).toHaveLength(KEY_REPORT_LENGTH);
    expect(report.readUInt8(0)).toBe(0x02);
    expect(report.readUInt8(1)).toBe(0x07);
    expect(report.readUInt8(2)).toBe(3); // key index
    expect(report.readUInt8(3)).toBe(1); // is_last
    expect(report.readUInt16LE(4)).toBe(5); // payload byte count LE
    expect(report.readUInt16LE(6)).toBe(0); // zero-based page LE
    expect([...report.subarray(8, 13)]).toEqual([1, 2, 3, 4, 5]);
    // Trailing bytes are zero-padded.
    expect(report.readUInt8(13)).toBe(0);
  });

  it("splits a large image into zero-based pages with is_last on the final chunk", () => {
    const jpeg = new Uint8Array(KEY_MAX_PAYLOAD * 2 + 10);
    for (let i = 0; i < jpeg.length; i += 1) jpeg[i] = i % 256;
    const reports = buildKeyImageReports(0, jpeg);
    expect(reports).toHaveLength(3);

    expect(reports[0].readUInt16LE(6)).toBe(0);
    expect(reports[0].readUInt16LE(4)).toBe(KEY_MAX_PAYLOAD);
    expect(reports[0].readUInt8(3)).toBe(0);

    expect(reports[1].readUInt16LE(6)).toBe(1);
    expect(reports[1].readUInt16LE(4)).toBe(KEY_MAX_PAYLOAD);
    expect(reports[1].readUInt8(3)).toBe(0);

    expect(reports[2].readUInt16LE(6)).toBe(2);
    expect(reports[2].readUInt16LE(4)).toBe(10);
    expect(reports[2].readUInt8(3)).toBe(1); // is_last

    // Reassembled payload matches the source.
    const reassembled = Buffer.concat(
      reports.map((r) => r.subarray(KEY_HEADER_LENGTH, KEY_HEADER_LENGTH + r.readUInt16LE(4))),
    );
    expect(reassembled.equals(Buffer.from(jpeg))).toBe(true);
  });

  it("emits exactly one full-payload terminating report when size is a multiple of the max", () => {
    const jpeg = new Uint8Array(KEY_MAX_PAYLOAD);
    const reports = buildKeyImageReports(1, jpeg);
    expect(reports).toHaveLength(1);
    expect(reports[0].readUInt8(3)).toBe(1);
    expect(reports[0].readUInt16LE(4)).toBe(KEY_MAX_PAYLOAD);
  });

  it("emits a single terminating report for an empty image", () => {
    const reports = buildKeyImageReports(7, new Uint8Array(0));
    expect(reports).toHaveLength(1);
    expect(reports[0].readUInt8(3)).toBe(1);
    expect(reports[0].readUInt16LE(4)).toBe(0);
    expect(reports[0].readUInt16LE(6)).toBe(0);
  });

  it("rejects out-of-range key indices", () => {
    expect(() => assertKeyIndex(-1)).toThrow(RangeError);
    expect(() => assertKeyIndex(KEY_COUNT)).toThrow(RangeError);
    expect(() => assertKeyIndex(1.5)).toThrow(RangeError);
    expect(() => buildKeyImageReports(8, new Uint8Array(1))).toThrow(RangeError);
    expect(() => assertKeyIndex(0)).not.toThrow();
  });
});

import { describe, expect, it } from "vitest";

import {
  buildRegionReports,
  COMMAND_TOUCHSCREEN_SET,
  HEADER_LENGTH,
  MAX_PAYLOAD,
  REPORT_ID,
  REPORT_LENGTH,
} from "../../src/imageWriter/headerGenerator.js";

const region = { x: 600, y: 0, width: 200, height: 100 };

function header(report: Buffer) {
  return {
    reportId: report.readUInt8(0),
    command: report.readUInt8(1),
    x: report.readUInt16LE(2),
    y: report.readUInt16LE(4),
    width: report.readUInt16LE(6),
    height: report.readUInt16LE(8),
    isLast: report.readUInt8(10),
    // Deliberately unaligned at offset 11.
    page: report.readUInt16LE(11),
    payloadCount: report.readUInt16LE(13),
    padding: report.readUInt8(15),
  };
}

describe("buildRegionReports", () => {
  it("emits a single fully-formed report for a small region", () => {
    const jpeg = Uint8Array.from({ length: 10 }, (_, i) => i + 1);
    const reports = buildRegionReports(region, jpeg);

    expect(reports).toHaveLength(1);
    const [report] = reports;
    expect(report.length).toBe(REPORT_LENGTH);
    expect(header(report)).toEqual({
      reportId: REPORT_ID,
      command: COMMAND_TOUCHSCREEN_SET,
      x: 600,
      y: 0,
      width: 200,
      height: 100,
      isLast: 1,
      page: 0,
      payloadCount: 10,
      padding: 0,
    });
    expect([...report.subarray(HEADER_LENGTH, HEADER_LENGTH + 10)]).toEqual([
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
    ]);
  });

  it("matches the header table exactly with little-endian multibyte fields", () => {
    // x=0x0102, page will be 0; use a region that exercises high/low bytes.
    const reports = buildRegionReports(
      { x: 0x0102, y: 0x0304, width: 0x00c8, height: 0x0064 },
      Uint8Array.of(0xff),
    );
    const report = reports[0];
    // x LE at 2..3
    expect(report[2]).toBe(0x02);
    expect(report[3]).toBe(0x01);
    // y LE at 4..5
    expect(report[4]).toBe(0x04);
    expect(report[5]).toBe(0x03);
    // width LE at 6..7
    expect(report[6]).toBe(0xc8);
    expect(report[7]).toBe(0x00);
    // height LE at 8..9
    expect(report[8]).toBe(0x64);
    expect(report[9]).toBe(0x00);
  });

  it("chunks large payloads across pages with an unaligned LE page index", () => {
    const total = MAX_PAYLOAD * 2 + 5;
    const jpeg = new Uint8Array(total).fill(0xab);
    const reports = buildRegionReports(region, jpeg);

    expect(reports).toHaveLength(3);

    expect(header(reports[0])).toMatchObject({ page: 0, isLast: 0, payloadCount: MAX_PAYLOAD });
    expect(header(reports[1])).toMatchObject({ page: 1, isLast: 0, payloadCount: MAX_PAYLOAD });
    expect(header(reports[2])).toMatchObject({ page: 2, isLast: 1, payloadCount: 5 });

    // Every report is full length; each carries the same region geometry.
    for (const report of reports) {
      expect(report.length).toBe(REPORT_LENGTH);
      expect(header(report)).toMatchObject({ x: 600, width: 200 });
    }

    // Reassembled payload equals the original.
    const reassembled = Buffer.concat(
      reports.map((r) => r.subarray(HEADER_LENGTH, HEADER_LENGTH + r.readUInt16LE(13))),
    );
    expect(reassembled.length).toBe(total);
    expect(reassembled.every((b) => b === 0xab)).toBe(true);
  });

  it("encodes a page index >255 as little-endian across the unaligned pair", () => {
    // 257 pages -> last page index 256 = 0x0100 -> bytes [0x00, 0x01] at 11,12.
    const total = MAX_PAYLOAD * 256 + 1;
    const jpeg = new Uint8Array(total);
    const reports = buildRegionReports(region, jpeg);
    const last = reports[reports.length - 1];
    expect(last.readUInt16LE(11)).toBe(256);
    expect(last[11]).toBe(0x00);
    expect(last[12]).toBe(0x01);
    expect(last.readUInt8(10)).toBe(1);
  });

  it("yields one terminating report for an empty payload", () => {
    const reports = buildRegionReports(region, new Uint8Array(0));
    expect(reports).toHaveLength(1);
    expect(header(reports[0])).toMatchObject({ page: 0, isLast: 1, payloadCount: 0 });
  });

  it("rejects out-of-range geometry", () => {
    expect(() => buildRegionReports({ x: -1, y: 0, width: 1, height: 1 }, new Uint8Array(1))).toThrow(
      RangeError,
    );
    expect(() =>
      buildRegionReports({ x: 0, y: 0, width: 0x10000, height: 1 }, new Uint8Array(1)),
    ).toThrow(RangeError);
  });
});

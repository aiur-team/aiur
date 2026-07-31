/**
 * Stream Deck + touch-strip partial-region write protocol (command `0x0C`).
 *
 * This module is the pure, transport-independent encoder for the touch strip.
 * It turns an already-encoded JPEG buffer for a rectangular region into the
 * exact sequence of 1024-byte HID feature reports the device expects. The
 * device transport (#1354) owns opening the deck, locking, and serializing the
 * writes; it feeds these reports to the hidraw handle in order.
 *
 * Reference: node's `packages/core/src/services/imageWriter/headerGenerator.ts`
 * is the cleanest statement of this header. Per the official spec the touch
 * strip is 800x100 px, JPEG, rotation 0, no flip, RGB, and image data is always
 * uploaded through `0x0C` partial-region writes — even a full-strip fill routes
 * through `0x0C` at (0,0,800,100). Full-window upload `0x0B` is intentionally
 * not used here.
 *
 * WARNING: Python's inline offset comments in `set_touchscreen_image` are
 * transposed and wrong. This module follows the table in the official docs and
 * the node reference, not those comments. All multi-byte fields are
 * little-endian.
 *
 * Report layout (length 1024, header 16, max payload 1008):
 *
 * | Offset | Size | Field                                          |
 * |--------|------|------------------------------------------------|
 * | 0      | 1    | `0x02`                                         |
 * | 1      | 1    | `0x0C`                                         |
 * | 2      | 2    | x (LE)                                          |
 * | 4      | 2    | y (LE)                                          |
 * | 6      | 2    | width (LE)                                      |
 * | 8      | 2    | height (LE)                                     |
 * | 10     | 1    | is_last (0 or 1)                               |
 * | 11     | 2    | page index (LE) — deliberately UNALIGNED       |
 * | 13     | 2    | payload byte count (LE)                        |
 * | 15     | 1    | `0x00` padding                                 |
 * | 16     | 1008 | JPEG chunk                                      |
 */

/** Full HID feature report length, in bytes. */
export const REPORT_LENGTH = 1024;

/** Fixed header length, in bytes. */
export const HEADER_LENGTH = 16;

/** Maximum JPEG payload carried by a single report. */
export const MAX_PAYLOAD = REPORT_LENGTH - HEADER_LENGTH; // 1008

/** Report id byte at offset 0. */
export const REPORT_ID = 0x02;

/** Touch-strip partial-region write command at offset 1. */
export const COMMAND_TOUCHSCREEN_SET = 0x0c;

/** A rectangular region of the 800x100 touch strip. */
export interface Region {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

function assertUint16(value: number, field: string): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xffff) {
    throw new RangeError(`${field} must be a uint16 (0..65535), got ${value}`);
  }
}

/**
 * Encode one JPEG buffer covering `region` into the ordered sequence of
 * 1024-byte `0x0C` reports. Each report repeats the region geometry, carries a
 * zero-based page index (unaligned at offset 11), the chunk's payload length,
 * and sets `is_last` on the final chunk. Trailing report bytes are zero-padded
 * so every returned buffer is exactly {@link REPORT_LENGTH} bytes.
 *
 * An empty JPEG still yields a single terminating report (page 0, is_last=1,
 * payload length 0), which paints nothing but keeps the page sequence
 * well-formed.
 */
export function buildRegionReports(region: Region, jpeg: Uint8Array): Buffer[] {
  assertUint16(region.x, "x");
  assertUint16(region.y, "y");
  assertUint16(region.width, "width");
  assertUint16(region.height, "height");

  const reports: Buffer[] = [];
  const total = jpeg.length;
  let offset = 0;
  let page = 0;

  do {
    const remaining = total - offset;
    const chunkLength = Math.min(remaining, MAX_PAYLOAD);
    const isLast = offset + chunkLength >= total;

    const report = Buffer.alloc(REPORT_LENGTH);
    report.writeUInt8(REPORT_ID, 0);
    report.writeUInt8(COMMAND_TOUCHSCREEN_SET, 1);
    report.writeUInt16LE(region.x, 2);
    report.writeUInt16LE(region.y, 4);
    report.writeUInt16LE(region.width, 6);
    report.writeUInt16LE(region.height, 8);
    report.writeUInt8(isLast ? 1 : 0, 10);
    // Page index is deliberately unaligned at offset 11.
    report.writeUInt16LE(page, 11);
    report.writeUInt16LE(chunkLength, 13);
    report.writeUInt8(0x00, 15);

    if (chunkLength > 0) {
      report.set(jpeg.subarray(offset, offset + chunkLength), HEADER_LENGTH);
    }

    reports.push(report);
    offset += chunkLength;
    page += 1;
  } while (offset < total);

  return reports;
}

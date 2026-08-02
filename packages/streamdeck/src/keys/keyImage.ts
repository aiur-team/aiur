/**
 * Stream Deck + key-image write protocol (output report `0x07`).
 *
 * This module is the pure, transport-independent encoder for a single key. It
 * turns an already-encoded JPEG buffer for one 120x120 key into the exact
 * ordered sequence of 1024-byte HID output reports the device expects. The
 * device transport (#1354) owns opening the deck, locking, and serializing the
 * writes onto the hidraw handle; it feeds these reports out in order (see
 * `writeQueue.ts` for the serialization contract this package guarantees).
 *
 * Reference: the header below is verified identical across the three reference
 * libraries (python-elgato-streamdeck, `@elgato-stream-deck/node`, the Rust
 * `elgato-streamdeck` crate) for the Stream Deck **Plus** specifically. Do NOT
 * copy orientation handling from a sibling device: the Plus is 120x120, JPEG,
 * rotation 0, no flip, RGB order, and — critically — **zero-based** page
 * numbering. Gen1 Original starts pages at 1; XL/MK.2 are JPEG but flipped on
 * both axes; Mini/gen1 are BMP. None of that applies here.
 *
 * All multi-byte fields are little-endian.
 *
 * Report layout (length 1024, header 8, max payload 1016):
 *
 * | Offset | Size | Field                                   |
 * |--------|------|-----------------------------------------|
 * | 0      | 1    | `0x02` output report id                 |
 * | 1      | 1    | `0x07` set image                        |
 * | 2      | 1    | key index                               |
 * | 3      | 1    | is_last (1 = final chunk)               |
 * | 4      | 2    | payload byte count (LE)                 |
 * | 6      | 2    | page/chunk index (LE), zero-based       |
 * | 8      | 1016 | JPEG chunk                              |
 */

/**
 * How a report must be delivered over hidraw. The Plus mixes two transport
 * kinds on the same key stream: `0x02` image chunks go out via `hid.write()`
 * (an OUTPUT report), while the `0x03` RGB fill goes out via
 * `sendFeatureReport()` (a FEATURE report). The bytes alone do not tell the
 * transport (#1354/#1423) which call to make, so every report is tagged.
 */
export type ReportKind = "output" | "feature";

/** A single built HID report plus the transport call it must be written with. */
export interface KeyReport {
  readonly kind: ReportKind;
  readonly data: Buffer;
}

/** Full HID output report length, in bytes (host zero-pads to this). */
export const KEY_REPORT_LENGTH = 1024;

/** Fixed key-image header length, in bytes. */
export const KEY_HEADER_LENGTH = 8;

/** Maximum JPEG payload carried by a single key-image report. */
export const KEY_MAX_PAYLOAD = KEY_REPORT_LENGTH - KEY_HEADER_LENGTH; // 1016

/** Output report id byte at offset 0. */
export const KEY_REPORT_ID = 0x02;

/** Set-image command byte at offset 1. */
export const KEY_COMMAND_SET_IMAGE = 0x07;

/** Number of physical keys on a Stream Deck Plus (4 columns x 2 rows). */
export const KEY_COUNT = 8;

/** Edge length in pixels of a single square key on the Plus. */
export const KEY_IMAGE_SIZE = 120;

/** Throws unless `index` is a valid key index for the Plus (0..7). */
export function assertKeyIndex(index: number): void {
  if (!Number.isInteger(index) || index < 0 || index >= KEY_COUNT) {
    throw new RangeError(
      `key index must be an integer in 0..${KEY_COUNT - 1}, got ${index}`,
    );
  }
}

/**
 * Encode one key's JPEG buffer into the ordered sequence of 1024-byte `0x07`
 * reports for `keyIndex`. Each report carries the key index, a zero-based page
 * index (offset 6, LE), the chunk's payload length (offset 4, LE), and sets
 * `is_last` on the final chunk. Trailing report bytes are zero-padded so every
 * returned buffer is exactly {@link KEY_REPORT_LENGTH} bytes.
 *
 * An empty JPEG still yields a single terminating report (page 0, is_last=1,
 * payload length 0). That keeps the page sequence well-formed; it is not a
 * meaningful image and callers should prefer the RGB fast path (`keyFill.ts`)
 * for solid fills rather than encoding a solid JPEG.
 */
export function buildKeyImageReports(keyIndex: number, jpeg: Uint8Array): KeyReport[] {
  assertKeyIndex(keyIndex);

  const reports: KeyReport[] = [];
  const total = jpeg.length;
  let offset = 0;
  let page = 0;

  do {
    const remaining = total - offset;
    const chunkLength = Math.min(remaining, KEY_MAX_PAYLOAD);
    const isLast = offset + chunkLength >= total;

    const report = Buffer.alloc(KEY_REPORT_LENGTH);
    report.writeUInt8(KEY_REPORT_ID, 0);
    report.writeUInt8(KEY_COMMAND_SET_IMAGE, 1);
    report.writeUInt8(keyIndex, 2);
    report.writeUInt8(isLast ? 1 : 0, 3);
    report.writeUInt16LE(chunkLength, 4);
    report.writeUInt16LE(page, 6);

    if (chunkLength > 0) {
      report.set(jpeg.subarray(offset, offset + chunkLength), KEY_HEADER_LENGTH);
    }

    reports.push({ kind: "output", data: report });
    offset += chunkLength;
    page += 1;
  } while (offset < total);

  return reports;
}

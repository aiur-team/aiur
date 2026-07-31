/**
 * Stream Deck + RGB key fill fast path (feature report `0x03 0x06`).
 *
 * For solid colours — blackouts, flat status fills — the Plus supports a
 * feature-report key fill that is vastly cheaper than a JPEG upload: a single
 * 32-byte report instead of a multi-report `0x07` image transfer. The renderer
 * routes empty/solid keys through here and reserves `keyImage.ts` for real
 * pixel content.
 *
 * Report layout (length 32):
 *
 * | Offset | Size | Field                         |
 * |--------|------|-------------------------------|
 * | 0      | 1    | `0x03` feature report id      |
 * | 1      | 1    | `0x06` set key colour         |
 * | 2      | 1    | key index (see index base)    |
 * | 3      | 1    | red                           |
 * | 4      | 1    | green                         |
 * | 5      | 1    | blue                          |
 * | 6..31  | 26   | `0x00` padding                |
 *
 * ## Index base — UNRESOLVED, verify on hardware
 *
 * The reference libraries disagree on the key index for THIS command only:
 * `@elgato-stream-deck/node` passes the raw key index, while the Rust
 * `elgato-streamdeck` crate offsets it by `+ key_count()`. Both cannot be
 * correct on the same device. We default to {@link FillIndexBase} `"raw"` (the
 * node convention) because the #1342 spike used `@elgato-stream-deck/node` to
 * enumerate and identify the physical Plus, making it our primary reference for
 * this device. The `"key-count-offset"` base is exposed so the value can be
 * flipped and confirmed on hardware without a code change, and the finding
 * recorded. Until confirmed on a real Plus, treat the default as provisional.
 */

/** An 8-bit-per-channel RGB colour. */
export interface RgbColor {
  readonly r: number;
  readonly g: number;
  readonly b: number;
}

/**
 * Which index convention to send for the `0x06` fill command.
 *
 * - `"raw"` — send the key index unchanged (node convention, our default).
 * - `"key-count-offset"` — send `keyIndex + KEY_COUNT` (Rust crate convention).
 */
export type FillIndexBase = "raw" | "key-count-offset";

import { KEY_COUNT, assertKeyIndex, type KeyReport } from "./keyImage.js";

/** Full RGB fill feature-report length, in bytes. */
export const KEY_FILL_REPORT_LENGTH = 32;

/** Feature report id byte at offset 0. */
export const KEY_FILL_REPORT_ID = 0x03;

/** Set-key-colour command byte at offset 1. */
export const KEY_FILL_COMMAND = 0x06;

/** The default index base for the fill command; provisional until hardware-confirmed. */
export const DEFAULT_FILL_INDEX_BASE: FillIndexBase = "raw";

function assertChannel(value: number, channel: string): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xff) {
    throw new RangeError(`${channel} must be a uint8 (0..255), got ${value}`);
  }
}

/** Resolves the wire index for `keyIndex` under the chosen index base. */
export function fillDeviceIndex(keyIndex: number, base: FillIndexBase): number {
  return base === "key-count-offset" ? keyIndex + KEY_COUNT : keyIndex;
}

/**
 * Build the single 32-byte feature report that fills `keyIndex` with `color`.
 * `base` selects the index convention (see {@link FillIndexBase}); it defaults
 * to the provisional {@link DEFAULT_FILL_INDEX_BASE}.
 */
export function buildKeyFillReport(
  keyIndex: number,
  color: RgbColor,
  base: FillIndexBase = DEFAULT_FILL_INDEX_BASE,
): KeyReport {
  assertKeyIndex(keyIndex);
  assertChannel(color.r, "r");
  assertChannel(color.g, "g");
  assertChannel(color.b, "b");

  const report = Buffer.alloc(KEY_FILL_REPORT_LENGTH);
  report.writeUInt8(KEY_FILL_REPORT_ID, 0);
  report.writeUInt8(KEY_FILL_COMMAND, 1);
  report.writeUInt8(fillDeviceIndex(keyIndex, base), 2);
  report.writeUInt8(color.r, 3);
  report.writeUInt8(color.g, 4);
  report.writeUInt8(color.b, 5);
  // Feature report: the transport must send this via `sendFeatureReport()`,
  // never `hid.write()`.
  return { kind: "feature", data: report };
}

/** Solid black — the canonical blackout fill for empty keys. */
export const BLACK: RgbColor = Object.freeze({ r: 0, g: 0, b: 0 });

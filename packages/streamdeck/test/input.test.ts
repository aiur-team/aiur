import { describe, expect, it } from "vitest";
import { decodeInputReport, risingEdges } from "../src/input.js";

describe("Stream Deck + input reports", () => {
  it("decodes button state changes at the documented offset", () => {
    expect(decodeInputReport(Uint8Array.from([0x01, 0x00, 0, 0, 1, 0]))).toEqual([
      { type: "key", index: 0, pressed: true },
      { type: "key", index: 1, pressed: false },
    ]);
  });

  it("ignores malformed and unsupported reports", () => {
    expect(decodeInputReport(Uint8Array.from([0x00, 0x00, 0, 0, 1]))).toEqual([]);
    expect(decodeInputReport(Uint8Array.from([0x01, 0x02, 0, 0, 0]))).toEqual([]);
    expect(decodeInputReport(Uint8Array.from([0x01, 0x03, 0, 0, 0x04, 0]))).toEqual([]);
  });

  it("decodes signed encoder ticks and button state", () => {
    expect(decodeInputReport(Uint8Array.from([0x01, 0x03, 0, 0, 0x01, 0xff, 0x02]))).toEqual([
      { type: "encoder-turn", index: 0, ticks: -1 },
      { type: "encoder-turn", index: 1, ticks: 2 },
    ]);
    expect(decodeInputReport(Uint8Array.from([0x01, 0x03, 0, 0, 0x00, 0x01, 0x00]))).toEqual([
      { type: "encoder-button", index: 0, pressed: true },
      { type: "encoder-button", index: 1, pressed: false },
    ]);
  });

  it("turns level reports into one control edge", () => {
    const first = risingEdges([{ type: "key", index: 2, pressed: true }], new Set());
    expect(first.events).toEqual([{ type: "key", index: 2, pressed: true }]);
    expect(risingEdges([{ type: "key", index: 2, pressed: true }], first.pressed).events).toEqual([]);
    expect(risingEdges([{ type: "key", index: 2, pressed: false }], first.pressed).pressed.size).toBe(0);
    expect(risingEdges([{ type: "encoder-turn", index: 3, ticks: 1 }], new Set()).events).toEqual([]);
  });
});

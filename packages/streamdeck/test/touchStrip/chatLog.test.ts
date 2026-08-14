import { describe, expect, it } from "vitest";

import { CHAT_WINDOW_ROWS, ensureEventVisible, eventKeyAtOffset } from "../../src/touchStrip/chatLog.js";

describe("CHAT_WINDOW_ROWS", () => {
  it("shows more than the two rows the strip used to", () => {
    expect(CHAT_WINDOW_ROWS).toBeGreaterThan(2);
  });
});

describe("eventKeyAtOffset", () => {
  // Headers at 0, 4 and 9; key n + 1 owns start n, because key 0 is LIVE.
  const starts = [0, 4, 9];

  it("maps an offset to the event key that contains it", () => {
    expect(eventKeyAtOffset(starts, 0)).toBe(1);
    expect(eventKeyAtOffset(starts, 3)).toBe(1);
    expect(eventKeyAtOffset(starts, 4)).toBe(2);
    expect(eventKeyAtOffset(starts, 8)).toBe(2);
    expect(eventKeyAtOffset(starts, 9)).toBe(3);
    expect(eventKeyAtOffset(starts, 40)).toBe(3);
  });

  /**
   * Entries can arrive ahead of the header they belong to. Highlighting nothing
   * is honest there; snapping to the first key would claim the operator is
   * reading an event they are not.
   */
  it("selects nothing above the first header", () => {
    expect(eventKeyAtOffset([2, 6], 0)).toBeNull();
    expect(eventKeyAtOffset([2, 6], 1)).toBeNull();
    expect(eventKeyAtOffset([], 0)).toBeNull();
  });
});

describe("ensureEventVisible", () => {
  it("leaves the window alone when the key is already inside it", () => {
    expect(ensureEventVisible(4, 4, 20)).toBe(4);
    expect(ensureEventVisible(4, 11, 20)).toBe(4);
  });

  it("scrolls back to the key when it sits above the window", () => {
    expect(ensureEventVisible(10, 3, 20)).toBe(3);
  });

  it("scrolls forward the minimum needed when the key sits below the window", () => {
    expect(ensureEventVisible(0, 9, 20)).toBe(2);
  });

  it("never scrolls past the ends of the event list", () => {
    expect(ensureEventVisible(0, 30, 5)).toBe(5);
    expect(ensureEventVisible(-4, 0, 5)).toBe(0);
    expect(ensureEventVisible(9, 2, 0)).toBe(0);
  });
});

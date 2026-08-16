import { describe, expect, it } from "vitest";

import { CHAT_WINDOW_ROWS, ensureEventVisible, selectedKeyAtOffset } from "../../src/touchStrip/chatLog.js";

describe("CHAT_WINDOW_ROWS", () => {
  it("shows more than the two rows the strip used to", () => {
    expect(CHAT_WINDOW_ROWS).toBeGreaterThan(2);
  });
});

describe("selectedKeyAtOffset", () => {
  // Three event headers at 0, 4 and 9, then LIVE — which is the last key, not
  // the first, because the surface reads oldest-left to newest-right.
  const starts = [0, 4, 9, 12];
  const chatMax = 12;

  it("maps an offset to the event key that contains it", () => {
    expect(selectedKeyAtOffset(starts, 0, chatMax)).toBe(0);
    expect(selectedKeyAtOffset(starts, 3, chatMax)).toBe(0);
    expect(selectedKeyAtOffset(starts, 4, chatMax)).toBe(1);
    expect(selectedKeyAtOffset(starts, 8, chatMax)).toBe(1);
    expect(selectedKeyAtOffset(starts, 9, chatMax)).toBe(2);
    expect(selectedKeyAtOffset(starts, 11, chatMax)).toBe(2);
  });

  /**
   * Sitting on the newest row is what "live" means. This is the half of the
   * selection contract that makes LIVE and an event mutually exclusive without
   * either needing a rule of its own.
   */
  it("selects LIVE at the end of the transcript, and only there", () => {
    expect(selectedKeyAtOffset(starts, chatMax, chatMax)).toBe(3);
    expect(selectedKeyAtOffset(starts, chatMax + 5, chatMax)).toBe(3);
    expect(selectedKeyAtOffset(starts, chatMax - 1, chatMax)).not.toBe(3);
  });

  /**
   * The origin anchor guarantees a key at offset 0, so "above every header"
   * cannot happen. If a feed ever omits it, fall back to the first key rather
   * than leaving the surface with nothing active — every offset belongs to
   * something now.
   */
  it("falls back to the first key when the feed omits the origin anchor", () => {
    expect(selectedKeyAtOffset([2, 6, 9], 0, 9)).toBe(0);
    expect(selectedKeyAtOffset([2, 6, 9], 1, 9)).toBe(0);
  });

  it("has no selection when there are no keys at all", () => {
    expect(selectedKeyAtOffset([], 0, 0)).toBeNull();
  });
});

describe("ensureEventVisible", () => {
  it("leaves the window alone when the key is already inside it", () => {
    expect(ensureEventVisible(4, 4, 20)).toBe(4);
    // The last event slot is offset + 6; position 7 belongs to pinned LIVE.
    expect(ensureEventVisible(4, 10, 20)).toBe(4);
    expect(ensureEventVisible(4, 6, 20)).toBe(4);
  });

  it("scrolls back to the key when it sits above the window", () => {
    expect(ensureEventVisible(10, 3, 20)).toBe(3);
  });

  it("scrolls forward the minimum needed when the key sits below the window", () => {
    // 7 event slots: a key at position 7 must move the window so it lands in
    // slot 6 (the last event slot before pinned LIVE).
    expect(ensureEventVisible(0, 9, 20)).toBe(3);
    expect(ensureEventVisible(0, 7, 20)).toBe(1);
  });

  it("chases the pinned LIVE key to the newest page when it is the selection", () => {
    // LIVE is the feed's last key (index maxOffset + 7); ensuring it visible
    // means scrolling the event window to its newest page.
    expect(ensureEventVisible(0, 19, 12)).toBe(12);
    expect(ensureEventVisible(4, 19, 12)).toBe(12);
  });

  it("never scrolls past the ends of the event list", () => {
    expect(ensureEventVisible(0, 30, 5)).toBe(5);
    expect(ensureEventVisible(-4, 0, 5)).toBe(0);
    expect(ensureEventVisible(9, 2, 0)).toBe(0);
  });
});

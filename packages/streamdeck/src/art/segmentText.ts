import type { SKRSContext2D } from "@napi-rs/canvas";

/**
 * Narrowest glyph any of the panel's fonts draws, used only to bound how much
 * of a long string can possibly fit before measuring it. Deliberately an
 * under-estimate: too small only costs a few extra measured characters, while
 * too large would clip text that would have fitted.
 */
const MIN_GLYPH_WIDTH = 3;

/**
 * Shortens `text` with an ellipsis until it fits `maxWidth` at the current font.
 *
 * Measured and clipped rather than left to a canvas clip region, because the
 * strip's panels are cached by their rendered bytes: a clipped glyph still
 * changes the JPEG, so two rows that read the same would repaint each other.
 */
export const fit = (context: SKRSContext2D, text: string, maxWidth: number): string => {
  // A caller can hand this a negative budget when a long right-aligned run eats
  // the panel; nothing fits, so draw nothing rather than the bare ellipsis.
  if (maxWidth <= 0) return "";

  // Pre-clip before measuring anything.
  //
  // The daemon caps a body at 1000 characters, not at what an 800px panel can
  // hold, and `measureText` cost scales with the string. No glyph in these
  // fonts is narrower than about 3px, so anything past `maxWidth / 3` cannot
  // possibly be inside the budget and never needs measuring.
  const ceiling = Math.ceil(maxWidth / MIN_GLYPH_WIDTH) + 1;
  const candidate = text.length > ceiling ? text.slice(0, ceiling) : text;
  if (candidate === text && context.measureText(text).width <= maxWidth) return text;

  // Binary search the cut rather than walking it one character at a time.
  //
  // The walk was O(n) measures over strings of near-full length: on this
  // panel's font a 1000-character row cost ~213ms, against ~1ms to encode the
  // whole 800x100 JPEG. Five such rows put a frame at ~700ms, and the typing
  // reveal asks for a frame every 40ms — so the render blocked the event loop
  // outright, and the USB poll stopped draining input rather than merely
  // painting late. The search is ~10 measures instead of ~900.
  let low = 0;
  let high = candidate.length;
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (context.measureText(`${candidate.slice(0, mid)}…`).width <= maxWidth) low = mid;
    else high = mid - 1;
  }
  return `${candidate.slice(0, Math.max(low, 1))}…`;
};

/** Draws `text` right-aligned to `right` and returns the width it used. */
export const rightText = (context: SKRSContext2D, text: string, right: number, y: number, color: string): number => {
  const width = context.measureText(text).width;
  context.fillStyle = color;
  context.fillText(text, right - width, y);
  return width;
};


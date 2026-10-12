import { createCanvas, type SKRSContext2D } from "@napi-rs/canvas";

import { drawSegmentContent } from "../../src/art/segments.js";
import type { SegmentContent } from "../../src/touchStrip/stripLayout.js";

export interface Ink {
  readonly text: string;
  readonly fill: string;
  /** Where the painter put it: a label that names a knob has to land over it. */
  readonly x: number;
  readonly y: number;
}

export const NOW = Date.parse("2026-08-13T03:00:00Z");

/** The panel background; every other pixel counts as something painted. */
export const BACKGROUND: readonly [number, number, number] = [0x0f, 0x12, 0x16];

export interface Render {
  /** Every string the painter drew, with the fill it used. */
  readonly ink: Ink[];
  /** Pixels that are not the flat background, i.e. proof something was drawn. */
  readonly inked: number;
  /** The finished panel, for comparing two renders. */
  readonly pixels: Uint8ClampedArray;
}

/**
 * Paints one panel and records every string drawn with the colour it was drawn
 * in. The device only ever shows pixels, so the assertions have to run against
 * what the painter actually put on the canvas.
 */
export const render = (content: SegmentContent, width = 200, now = NOW): Render => {
  const context = createCanvas(width, 100).getContext("2d");
  const ink: Ink[] = [];
  const original = context.fillText.bind(context) as SKRSContext2D["fillText"];
  context.fillText = ((text: string, x: number, y: number) => {
    ink.push({ text, fill: String(context.fillStyle), x, y });
    return original(text, x, y);
  }) as SKRSContext2D["fillText"];
  drawSegmentContent(context, content, width, now);

  // The divider stroke on the right edge is painted for every panel, so the
  // rightmost column is excluded from the ink count: it would otherwise report
  // a panel that drew nothing at all as inked.
  const { data } = context.getImageData(0, 0, width - 1, 100);
  let inked = 0;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i] !== BACKGROUND[0] || data[i + 1] !== BACKGROUND[1] || data[i + 2] !== BACKGROUND[2]) inked += 1;
  }
  return { ink, inked, pixels: data };
};


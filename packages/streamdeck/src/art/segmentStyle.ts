/** Shared palette, geometry and primitive painters of the touch-strip panels. */
import type { SKRSContext2D } from "@napi-rs/canvas";

import { createPaint } from "./gradient.js";

export const BG = "#0f1216";
export const DIVIDER = "rgba(255,255,255,0.10)";
export const LABEL = "rgba(255,255,255,0.55)";
export const TEXT = "#f1f3f6";
export const MUTED = "rgba(240,242,246,0.72)";
export const TRACK = "rgba(255,255,255,0.14)";
export const ACCENT_LIVE = "#4ade80";
export const DOT_ON = "#f1f3f6";
export const DOT_OFF = "rgba(255,255,255,0.28)";
export const CHIP_FILL = "rgba(255,255,255,0.08)";
export const CHIP_BORDER = "rgba(255,255,255,0.12)";
export const PAD = 12;
export const METER_HEIGHT = 8;
/** Full strip height; every panel is full height. */
export const HEIGHT = 100;

/*
 * Shared vertical grid for the 200-wide grid-mode panels. All four are read as
 * one strip, so the title, the value row and the bar must land on the same
 * baselines with the same bottom margin — otherwise the bars visibly stagger.
 */
/** Title baseline: "SUMMARY", a provider name, the agent count. */
export const TITLE_BASELINE = 30;
/** Font shared by every panel title. */
export const TITLE_FONT = "700 18px sans-serif";
/** Baseline for the label/value row above the bar. */
export const VALUE_BASELINE = 68;
/** Top of the bar; 100 - BAR_TOP - METER_HEIGHT is the bottom margin. */
export const BAR_TOP = 76;

/** Type size the event keys use for event text, shared by the chat readout. */
export const EVENT_TEXT_SIZE = 13;

export const clamp = (value: number, low: number, high: number): number => Math.max(low, Math.min(high, value));

/** Small uppercase caption used for panel headings. */
export const caption = (context: SKRSContext2D, text: string, x: number, y: number, color = LABEL): void => {
  context.font = "700 10px monospace";
  context.fillStyle = color;
  context.fillText(text.toUpperCase(), x, y);
};

/**
 * Fill for the strip's mini-bars, matching the mock's `.sd-mini-bar > i`.
 *
 * Deliberately NOT the agent progress fill. These bars show *consumption* —
 * quota used, build completed — and painting them in the same green as a
 * progress bar would make a provider at 100% of its rate limit read healthy
 * when it means the opposite. Agent progress is a single green because more
 * really is better; consumption stays blue.
 */
export const MINI_BAR_FILL = "linear-gradient(90deg,#3f8bff,#8fbcff)";

/** Builds the mini-bar gradient across the bar's own width. */
export const miniBarFill = (context: SKRSContext2D, x: number, width: number): string | CanvasGradient =>
  createPaint(context, MINI_BAR_FILL, x, 0, width, METER_HEIGHT);

/** A rounded meter with a filled portion; `fraction` is clamped to 0..1. */
export const meter = (
  context: SKRSContext2D,
  x: number,
  y: number,
  width: number,
  fraction: number,
  color: string | CanvasGradient,
  height = METER_HEIGHT,
  showZeroStub = false,
  fillAlpha = 1,
): void => {
  const clamped = clamp(fraction, 0, 1);
  context.beginPath();
  context.roundRect(x, y, width, height, height / 2);
  context.fillStyle = TRACK;
  context.fill();
  const filled = Math.round(width * clamped);
  if (filled > 0 || showZeroStub) {
    context.beginPath();
    context.roundRect(x, y, Math.max(filled, height), height, height / 2);
    context.fillStyle = color;
    context.globalAlpha = fillAlpha;
    context.fill();
    context.globalAlpha = 1;
  }
};


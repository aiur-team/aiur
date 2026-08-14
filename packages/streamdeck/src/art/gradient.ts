/**
 * CSS gradient tokens -> canvas paint.
 *
 * The shared key-face contract (`key-face-contract.json`) carries each bucket's
 * `glow` and `face` as CSS gradient strings, because the browser emulator and
 * the Claude Design mock consume them directly as `style="background: ..."`.
 * Canvas cannot: assigning a `linear-gradient(...)` string to `fillStyle` is
 * not a parse error, it is silently ignored, and the context keeps whatever
 * fill it had — black. That is precisely why every key on the physical deck
 * rendered as a black rectangle while the contract said otherwise.
 *
 * This module translates the one gradient form the contract actually uses —
 * `linear-gradient(180deg,#rrggbb,#rrggbb)` — into a real `CanvasGradient`, and
 * falls back to a solid colour for a plain hex token so callers can treat both
 * uniformly.
 */
import type { SKRSContext2D } from "@napi-rs/canvas";

/** A parsed gradient: its angle in degrees and its ordered colour stops. */
export interface ParsedGradient {
  readonly degrees: number;
  readonly stops: readonly string[];
}

const GRADIENT_PATTERN = /^linear-gradient\(\s*([\d.]+)deg\s*,(.+)\)$/i;

/**
 * Parses `linear-gradient(<n>deg, <colour>, ...)`. Returns `null` for anything
 * that is not a linear gradient — including a bare hex colour, which callers
 * handle as a solid fill.
 */
export const parseGradient = (token: string): ParsedGradient | null => {
  const match = GRADIENT_PATTERN.exec(token.trim());
  if (match === null) {
    return null;
  }
  const stops = match[2]
    .split(",")
    .map((stop) => stop.trim())
    .filter((stop) => stop.length > 0);
  return stops.length === 0 ? null : { degrees: Number.parseFloat(match[1]), stops };
};

/** Normalises a bare colour token to a canvas-acceptable CSS colour. */
export const asColor = (token: string): string => {
  const trimmed = token.trim();
  return /^[0-9a-f]{3,8}$/i.test(trimmed) ? `#${trimmed}` : trimmed;
};

/**
 * Builds a paint for `token` covering the box at (`x`, `y`, `width`, `height`).
 *
 * A gradient becomes a `CanvasGradient` whose axis follows the CSS angle
 * convention: 0deg points up, and the angle increases clockwise, so the
 * contract's `180deg` runs top-to-bottom. Anything else is returned as a solid
 * colour string.
 */
export const createPaint = (
  context: SKRSContext2D,
  token: string,
  x: number,
  y: number,
  width: number,
  height: number,
): string | CanvasGradient => {
  const parsed = parseGradient(token);
  if (parsed === null) {
    return asColor(token);
  }

  // CSS angles measure clockwise from "to top"; convert to a unit vector and
  // project it onto the box so the axis spans the full paint area.
  const radians = (parsed.degrees * Math.PI) / 180;
  const dx = Math.sin(radians);
  const dy = -Math.cos(radians);
  const halfSpan = (Math.abs(dx) * width + Math.abs(dy) * height) / 2;
  const centerX = x + width / 2;
  const centerY = y + height / 2;

  const gradient = context.createLinearGradient(
    centerX - dx * halfSpan,
    centerY - dy * halfSpan,
    centerX + dx * halfSpan,
    centerY + dy * halfSpan,
  );
  const lastStop = parsed.stops.length - 1;
  parsed.stops.forEach((stop, index) => {
    gradient.addColorStop(lastStop === 0 ? 0 : index / lastStop, asColor(stop));
  });
  return gradient;
};

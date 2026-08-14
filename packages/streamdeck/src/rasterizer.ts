/**
 * Canvas rasteriser for key faces and touch-strip segments.
 *
 * This is the pixel end of the Stream Deck pipeline: it turns the pure
 * {@link KeyFace} / {@link SegmentContent} descriptions into the JPEGs the HID
 * writers upload. The parity target is `docs/design/streamdeck/` — the verbatim
 * Stream Deck slice of the Claude Design mock — and the bucket colours come
 * from the shared `key-face-contract.json` that the browser emulator also
 * reads, so the two surfaces cannot drift apart on state colour.
 *
 * Three things here are load-bearing and easy to regress:
 *
 * - **Gradients are painted, not assigned.** The contract's `face`/`glow` are
 *   CSS gradient strings. Assigning one to `fillStyle` is silently ignored by
 *   canvas and leaves the previous fill in place, which is what rendered every
 *   key solid black. They go through {@link createPaint}.
 * - **The progress bar is hue-mapped**, `hsl(pct/100*125 72% 50%)`: red at 0%,
 *   green at 100%. A fixed accent colour is not parity.
 * - **Titles re-wrap with real glyph metrics** rather than the character-count
 *   heuristic the pure layer uses, which is what lets a 120px key fit three
 *   proportional lines.
 */
import { createCanvas, type Canvas, type SKRSContext2D } from "@napi-rs/canvas";
import { composeKeyFace, type AgentKeyFace, type KeyFace } from "./keys/keyFace.js";
import type { KeyDescriptor } from "./keys.js";
import type { SegmentContent } from "./touchStrip/stripLayout.js";
import { KEY_IMAGE_SIZE } from "./keys/keyImage.js";
import { SEGMENT_WIDTH, STRIP_HEIGHT as SEGMENT_HEIGHT } from "./touchStrip/geometry.js";
import { createPaint } from "./art/gradient.js";
import { drawIcon, iconFragment } from "./art/icons.js";
import { drawVendorMark } from "./art/vendorMark.js";
import { drawSegmentContent } from "./art/segments.js";

export interface RasterizerOptions {
  readonly jpegQuality?: number;
}

/* Key geometry, scaled from the mock's proportions to the 120px key. */
const KEY_RADIUS = 15;
const FACE_INSET = 3;
const FACE_RADIUS = 12;
const PAD_X = 9;
const TOP_Y = 10;
const ICON_CHIP = 26;
const ICON_GLYPH = 17;
const VENDOR_SIZE = 18;
const PRIORITY_SIZE = 12;
/**
 * Title type size. The mock's 1.08rem scales to ~15px on a 120px key, but at 15
 * a common word like "Orchestrator" is fractionally too wide for the 102px text
 * column and gets hard-split mid-word, which reads as a rendering fault. 14
 * keeps whole words intact and still runs well above the 12px this used to be.
 */
const TITLE_SIZE = 14;
const TITLE_LINE_HEIGHT = 17;
const TITLE_MAX_LINES = 3;
const TITLE_TOP = 54;
const FOOTER_BASE = 110;
const BAR_HEIGHT = 6;
const DOT_SIZE = 9;
const TAG_HEIGHT = 13;

const EMPTY_FILL = "#0a0b0d";
const TEXT_PRIMARY = "#f1f3f6";
const TEXT_TITLE = "rgba(240,242,246,0.92)";
const PRIORITY_COLOR = "#ffd166";
const CHIP_FILL = "rgba(255,255,255,0.08)";
const CHIP_BORDER = "rgba(255,255,255,0.12)";
const BAR_TRACK = "rgba(255,255,255,0.14)";
const TAG_READY_FILL = "rgba(74,200,130,0.2)";
const TAG_READY_TEXT = "#88e0a6";
const TAG_BLOCKED_FILL = "rgba(224,86,78,0.2)";
const TAG_BLOCKED_TEXT = "#ff9a90";

const quality = (value: number | undefined): number => Math.max(1, Math.min(100, Math.trunc(value ?? 90)));

/** Rounded rectangle path; `roundRect` is available on the napi context. */
const roundedPath = (
  context: SKRSContext2D,
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number,
): void => {
  context.beginPath();
  context.roundRect(x, y, width, height, radius);
};

/**
 * Greedily wraps `title` to at most `maxLines` lines that fit `maxWidth`,
 * measuring with the font already set on `context`. The final line is
 * ellipsised when content remains, and a single word wider than the line is
 * hard-split so it cannot overflow the key.
 */
export const wrapToWidth = (
  context: SKRSContext2D,
  title: string,
  maxWidth: number,
  maxLines: number,
): string[] => {
  const fits = (text: string): boolean => context.measureText(text).width <= maxWidth;

  // Break any word wider than a whole line into pieces that do fit, so the
  // greedy fill below only ever handles atoms it can place.
  const atoms: string[] = [];
  for (const word of title.trim().split(/\s+/).filter((word) => word.length > 0)) {
    let rest = word;
    while (rest.length > 0 && !fits(rest)) {
      let cut = 1;
      while (cut < rest.length && fits(rest.slice(0, cut + 1))) {
        cut += 1;
      }
      atoms.push(rest.slice(0, cut));
      rest = rest.slice(cut);
    }
    if (rest.length > 0) {
      atoms.push(rest);
    }
  }

  const lines: string[] = [];
  let current = "";
  for (const atom of atoms) {
    const candidate = current === "" ? atom : `${current} ${atom}`;
    if (fits(candidate)) {
      current = candidate;
      continue;
    }
    lines.push(current);
    current = atom;
  }
  if (current !== "") {
    lines.push(current);
  }

  if (lines.length <= maxLines) {
    return lines;
  }
  // Content remains past the last visible line: mark it rather than dropping it
  // silently, trimming until the ellipsis itself fits.
  const kept = lines.slice(0, maxLines);
  let last = kept[maxLines - 1];
  while (last.length > 0 && !fits(`${last}…`)) {
    last = last.slice(0, -1);
  }
  kept[maxLines - 1] = `${last}…`;
  return kept;
};

/** Paints the key's outer glow border and inner face gradient. */
const drawKeyPlate = (context: SKRSContext2D, face: AgentKeyFace): void => {
  roundedPath(context, 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE, KEY_RADIUS);
  context.fillStyle = createPaint(context, face.glow, 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE);
  context.fill();

  const inner = KEY_IMAGE_SIZE - FACE_INSET * 2;
  roundedPath(context, FACE_INSET, FACE_INSET, inner, inner, FACE_RADIUS);
  context.fillStyle = createPaint(context, face.face, FACE_INSET, FACE_INSET, inner, inner);
  context.fill();
};

/** Icon chip, provider mark, priority star and ticket number. */
const drawKeyHeader = (context: SKRSContext2D, face: AgentKeyFace): void => {
  roundedPath(context, PAD_X, TOP_Y, ICON_CHIP, ICON_CHIP, 8);
  context.fillStyle = CHIP_FILL;
  context.fill();
  context.strokeStyle = CHIP_BORDER;
  context.lineWidth = 1;
  context.stroke();

  const glyphOffset = (ICON_CHIP - ICON_GLYPH) / 2;
  drawIcon(context, iconFragment(face.icon), PAD_X + glyphOffset, TOP_Y + glyphOffset, ICON_GLYPH, face.accent);

  drawVendorMark(
    context,
    face.vendor,
    PAD_X + ICON_CHIP + 6,
    TOP_Y + (ICON_CHIP - VENDOR_SIZE) / 2,
    VENDOR_SIZE,
  );

  // Ticket number is right-aligned; the priority star sits just left of it.
  context.font = `700 17px monospace`;
  context.textAlign = "right";
  context.fillStyle = TEXT_PRIMARY;
  const numberY = TOP_Y + ICON_CHIP / 2 + 6;
  const label = `${face.ticketNumber}`;
  context.fillText(label, KEY_IMAGE_SIZE - PAD_X, numberY);

  if (face.priority) {
    const starX = KEY_IMAGE_SIZE - PAD_X - context.measureText(label).width - PRIORITY_SIZE - 3;
    drawPriorityStar(context, starX, numberY - PRIORITY_SIZE + 1, PRIORITY_SIZE);
  }
  context.textAlign = "left";
};

/** The mock's five-point priority star, filled. */
const drawPriorityStar = (context: SKRSContext2D, x: number, y: number, size: number): void => {
  const scale = size / 24;
  context.save();
  context.translate(x, y);
  context.scale(scale, scale);
  context.beginPath();
  context.moveTo(12, 3);
  context.lineTo(14.6, 8.7);
  context.lineTo(20.8, 9.3);
  context.lineTo(16.1, 13.5);
  context.lineTo(17.5, 19.6);
  context.lineTo(12, 17);
  context.lineTo(6.5, 19.6);
  context.lineTo(7.9, 13.5);
  context.lineTo(3.2, 9.3);
  context.lineTo(9.4, 8.7);
  context.closePath();
  context.fillStyle = PRIORITY_COLOR;
  context.fill();
  context.restore();
};

/**
 * Wrapped title, using real glyph metrics rather than a character count.
 *
 * A queued key's footer is two stacked rows (status label above the
 * blocked/unblocked pill) where every other state's is a single row, so a
 * queued title gets one line fewer. Without that the third line runs straight
 * through the status label.
 */
const drawKeyTitle = (context: SKRSContext2D, face: AgentKeyFace): void => {
  context.font = `600 ${TITLE_SIZE}px sans-serif`;
  context.fillStyle = TEXT_TITLE;
  const maxLines = face.footer.kind === "queued" ? TITLE_MAX_LINES - 1 : TITLE_MAX_LINES;
  const lines = wrapToWidth(context, face.title, KEY_IMAGE_SIZE - PAD_X * 2, maxLines);
  lines.forEach((line, index) => {
    context.fillText(line, PAD_X, TITLE_TOP + index * TITLE_LINE_HEIGHT);
  });
};

/** Status dot plus hue-mapped bar, or the queued status label and tag. */
const drawKeyFooter = (context: SKRSContext2D, face: AgentKeyFace): void => {
  if (face.footer.kind === "queued") {
    // Two stacked rows (the mock's `.sd-ag-foot.col`): status label above, the
    // blocked/unblocked pill below it. They must not share a baseline band.
    context.font = `700 11px sans-serif`;
    context.fillStyle = face.accent;
    context.fillText(face.footer.label, PAD_X, FOOTER_BASE - TAG_HEIGHT - 5);

    const tag = face.footer.statusLabel;
    context.font = `700 9px monospace`;
    const tagWidth = context.measureText(tag).width + 10;
    const tagTop = FOOTER_BASE - TAG_HEIGHT;
    roundedPath(context, PAD_X, tagTop, tagWidth, TAG_HEIGHT, TAG_HEIGHT / 2);
    context.fillStyle = face.footer.unblocked ? TAG_READY_FILL : TAG_BLOCKED_FILL;
    context.fill();
    context.fillStyle = face.footer.unblocked ? TAG_READY_TEXT : TAG_BLOCKED_TEXT;
    context.fillText(tag, PAD_X + 5, tagTop + TAG_HEIGHT - 3.5);
    return;
  }

  const dotY = FOOTER_BASE - DOT_SIZE;
  context.beginPath();
  context.arc(PAD_X + DOT_SIZE / 2, dotY + DOT_SIZE / 2, DOT_SIZE / 2, 0, Math.PI * 2);
  context.fillStyle = face.accent;
  context.fill();

  const barX = PAD_X + DOT_SIZE + 7;
  const barWidth = KEY_IMAGE_SIZE - PAD_X - barX;
  const barY = dotY + (DOT_SIZE - BAR_HEIGHT) / 2;
  roundedPath(context, barX, barY, barWidth, BAR_HEIGHT, BAR_HEIGHT / 2);
  context.fillStyle = BAR_TRACK;
  context.fill();

  const filled = Math.round((barWidth * face.footer.percent) / 100);
  if (filled > 0) {
    roundedPath(context, barX, barY, Math.max(filled, BAR_HEIGHT), BAR_HEIGHT, BAR_HEIGHT / 2);
    context.fillStyle = face.footer.barColor;
    context.fill();
  }
};

const drawKey = (canvas: Canvas, face: KeyFace): void => {
  const context = canvas.getContext("2d");
  if (face.kind === "empty") {
    context.fillStyle = EMPTY_FILL;
    context.fillRect(0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE);
    return;
  }
  drawKeyPlate(context, face);
  drawKeyHeader(context, face);
  drawKeyTitle(context, face);
  drawKeyFooter(context, face);
};

const drawSegment = (canvas: Canvas, content: SegmentContent): void => {
  drawSegmentContent(canvas.getContext("2d"), content);
};

export const createRasterizer = (options: RasterizerOptions = {}) => {
  const jpegQuality = quality(options.jpegQuality);
  const cache = new Map<string, Uint8Array>();
  const encode = (canvas: Canvas): Uint8Array => Uint8Array.from(canvas.toBuffer("image/jpeg", jpegQuality));
  return {
    key: (descriptor: KeyDescriptor): Uint8Array => {
      const cacheKey = `key:${JSON.stringify(descriptor)}`;
      const cached = cache.get(cacheKey);
      if (cached !== undefined) return cached.slice();
      const canvas = createCanvas(KEY_IMAGE_SIZE, KEY_IMAGE_SIZE);
      drawKey(canvas, composeKeyFace(descriptor));
      const encoded = encode(canvas);
      cache.set(cacheKey, encoded);
      return encoded.slice();
    },
    segment: (content: SegmentContent): Uint8Array => {
      const cacheKey = `segment:${JSON.stringify(content)}`;
      const cached = cache.get(cacheKey);
      if (cached !== undefined) return cached.slice();
      const canvas = createCanvas(SEGMENT_WIDTH, SEGMENT_HEIGHT);
      drawSegment(canvas, content);
      const encoded = encode(canvas);
      cache.set(cacheKey, encoded);
      return encoded.slice();
    },
  };
};

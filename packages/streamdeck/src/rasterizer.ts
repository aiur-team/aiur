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
import { commandFragment, commandIsFilled, drawIcon, iconFragment } from "./art/icons.js";
import { KEY_FACE_CONTRACT } from "./key-face-contract.js";
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
/** Width of the left rail that marks the active event key. */
const SELECTION_RAIL = 5;

const EMPTY_FILL = "#0a0b0d";
const TEXT_PRIMARY = "#f1f3f6";
const TEXT_TITLE = "rgba(240,242,246,0.92)";
const CHIP_FILL = "rgba(255,255,255,0.08)";
const CHIP_BORDER = "rgba(255,255,255,0.12)";
const BAR_TRACK = "rgba(255,255,255,0.14)";
const TAG_READY_FILL = "rgba(74,200,130,0.2)";
const TAG_READY_TEXT = "#88e0a6";
const TAG_BLOCKED_FILL = "rgba(224,86,78,0.2)";
const TAG_BLOCKED_TEXT = "#ff9a90";

const quality = (value: number | undefined): number => Math.max(1, Math.min(100, Math.trunc(value ?? 90)));

/**
 * Badge colour for an event direction, from the shared contract's
 * `direction_badges`, so the log surface and the dashboard agree. An unknown
 * direction falls back to the neutral INFO colour.
 */
const directionColor = (direction: string): string => {
  const badges = KEY_FACE_CONTRACT.direction_badges as Readonly<Record<string, { color: string }>>;
  return (badges[direction.toUpperCase()] ?? badges.INFO).color;
};

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

  // Ticket number, right-aligned.
  //
  // The mock puts a gold star here for a prioritised ticket. It is omitted by
  // operator request: on a 120px key it reads as an unexplained decoration, and
  // priority is already expressed by the agent's position in the ranked order.
  // `priority` stays on the descriptor — the server sorts by it.
  context.font = `700 17px monospace`;
  context.textAlign = "right";
  context.fillStyle = TEXT_PRIMARY;
  const numberY = TOP_Y + ICON_CHIP / 2 + 6;
  context.fillText(`${face.ticketNumber}`, KEY_IMAGE_SIZE - PAD_X, numberY);
  context.textAlign = "left";
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
  const unknown = face.footer.percent === null;
  context.beginPath();
  context.arc(PAD_X + DOT_SIZE / 2, dotY + DOT_SIZE / 2, DOT_SIZE / 2 - (unknown ? 0.75 : 0), 0, Math.PI * 2);
  if (unknown) {
    // Hollow dot: the key still reports its bucket, but nothing is claimed
    // about how far along it is.
    context.strokeStyle = face.accent;
    context.lineWidth = 1.5;
    context.stroke();
  } else {
    context.fillStyle = face.accent;
    context.fill();
  }

  const barX = PAD_X + DOT_SIZE + 7;
  const barWidth = KEY_IMAGE_SIZE - PAD_X - barX;
  const barY = dotY + (DOT_SIZE - BAR_HEIGHT) / 2;
  roundedPath(context, barX, barY, barWidth, BAR_HEIGHT, BAR_HEIGHT / 2);
  context.fillStyle = BAR_TRACK;
  context.fill();

  if (unknown) {
    // A dashed track, and no fill at all. This is the state that used to be
    // indistinguishable from a real 0%: both painted an empty track, so a
    // ticket whose reading had merely gone stale looked like a ticket that had
    // done nothing. Dashes say "no reading", a solid stub says "zero".
    context.strokeStyle = face.footer.barColor;
    context.lineWidth = BAR_HEIGHT;
    context.setLineDash([4, 5]);
    context.beginPath();
    context.moveTo(barX + 2, barY + BAR_HEIGHT / 2);
    context.lineTo(barX + barWidth - 2, barY + BAR_HEIGHT / 2);
    context.stroke();
    context.setLineDash([]);
    context.lineWidth = 1;
    return;
  }

  // `Math.max(..., BAR_HEIGHT)` deliberately applies at 0 as well: a known 0%
  // paints a visible stub. Skipping the fill there is what made "just started"
  // and "no reading" the same picture.
  const filled = Math.max(Math.round((barWidth * face.footer.percent) / 100), BAR_HEIGHT);
  // A retained-but-stale reading is the truth, drawn as not-current rather than
  // replaced by a fabricated zero.
  const stale = face.footer.freshness === "stale";
  if (stale) context.globalAlpha = 0.5;
  roundedPath(context, barX, barY, filled, BAR_HEIGHT, BAR_HEIGHT / 2);
  context.fillStyle = face.footer.barColor;
  context.fill();
  context.globalAlpha = 1;
  if (stale) {
    context.strokeStyle = face.footer.barColor;
    context.lineWidth = 1;
    roundedPath(context, barX, barY, barWidth, BAR_HEIGHT, BAR_HEIGHT / 2);
    context.stroke();
  }
};

/**
 * A per-agent command key: one large centred glyph over a label and caption.
 * The mic key is the exception — while held it turns green, which is the only
 * feedback the operator has that the hold registered.
 */
const drawCommandKey = (context: SKRSContext2D, face: AgentKeyFace): void => {
  const live = face.icon === "mic" && face.subLabel.toUpperCase() === "LIVE";
  roundedPath(context, 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE, KEY_RADIUS);
  context.fillStyle = live
    ? createPaint(context, "linear-gradient(180deg,#37d97e,#1f9c56)", 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE)
    : "#1b1e25";
  context.fill();

  const inner = KEY_IMAGE_SIZE - FACE_INSET * 2;
  roundedPath(context, FACE_INSET, FACE_INSET, inner, inner, FACE_RADIUS);
  context.fillStyle = createPaint(
    context,
    live ? "linear-gradient(180deg,#17402a,#0f1a13)" : "linear-gradient(180deg,#1a1d24,#111318)",
    FACE_INSET,
    FACE_INSET,
    inner,
    inner,
  );
  context.fill();

  const glyph = 38;
  drawIcon(
    context,
    commandFragment(face.icon),
    (KEY_IMAGE_SIZE - glyph) / 2,
    26,
    glyph,
    live ? "#eafff3" : "#ffffff",
    commandIsFilled(face.icon),
  );

  context.textAlign = "center";
  context.font = "700 15px sans-serif";
  context.fillStyle = live ? "#eafff3" : TEXT_PRIMARY;
  context.fillText(face.title, KEY_IMAGE_SIZE / 2, 88);
  if (face.subLabel !== "") {
    context.font = "700 9px monospace";
    context.fillStyle = live ? "rgba(234,255,243,0.85)" : "rgba(240,242,246,0.55)";
    context.fillText(face.subLabel.toUpperCase(), KEY_IMAGE_SIZE / 2, 103);
  }
  context.textAlign = "left";
};

/**
 * The log feed's first row: a distinct live indicator, not an event. The mock
 * gives it a green plate and a pulsing dot; a static JPEG keeps the plate and
 * the dot without the pulse.
 */
/** Bright green plate for "you are watching this live", loud on purpose. */
const LIVE_GLOW = "linear-gradient(180deg,#37d97e,#1f9c56)";
const LIVE_FACE = "linear-gradient(180deg,#17402a,#0f2419)";

/**
 * The LIVE key: a root-level agent key whose title slot reads `LIVE`.
 *
 * It carries the same furniture as a grid key — lane icon chip, provider mark,
 * ticket number, and the progress bar — because it is the only key on the logs
 * surface that describes the ticket rather than one thing that happened to it.
 * Painting it as a bare green label meant that opening logs hid the very
 * numbers the operator had been watching one screen earlier.
 *
 * When LIVE is the active view the whole plate goes bright green, which is the
 * loudest state available on a 120px key and the point of the requirement: from
 * across a desk you can see whether you are watching the agent work or reading
 * back through history.
 */
const drawLiveKey = (context: SKRSContext2D, face: AgentKeyFace): void => {
  roundedPath(context, 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE, KEY_RADIUS);
  context.fillStyle = createPaint(context, face.selected ? LIVE_GLOW : face.glow, 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE);
  context.fill();

  const inner = KEY_IMAGE_SIZE - FACE_INSET * 2;
  roundedPath(context, FACE_INSET, FACE_INSET, inner, inner, FACE_RADIUS);
  context.fillStyle = createPaint(context, face.selected ? LIVE_FACE : face.face, FACE_INSET, FACE_INSET, inner, inner);
  context.fill();

  drawKeyHeader(context, face);

  // Centred, where an agent key's wrapped title would start. A single word in
  // the title slot is the whole difference between this key and a grid key.
  const label = face.title === "" ? "LIVE" : face.title;
  context.font = "800 20px sans-serif";
  const labelWidth = context.measureText(label).width;
  const dot = 9;
  const startX = (KEY_IMAGE_SIZE - (labelWidth + dot + 8)) / 2;

  context.beginPath();
  context.arc(startX + dot / 2, TITLE_TOP - 5, dot / 2, 0, Math.PI * 2);
  context.fillStyle = face.selected ? "#eafff3" : "#4ade80";
  context.fill();

  context.fillStyle = face.selected ? "#eafff3" : "#8fe0a8";
  context.fillText(label, startX + dot + 8, TITLE_TOP + 2);

  drawKeyFooter(context, face);
};

/**
 * A log-surface key: direction badge over the event text, timestamp
 * bottom-right.
 *
 * A selected key is lifted with the badge's own colour rather than a generic
 * highlight: the operator arrives at the selection either by pressing this key
 * or by scrolling the strip into this event, and in the second case the badge
 * colour is the fastest way to confirm the strip and the key are showing the
 * same thing.
 */
const drawEventKey = (context: SKRSContext2D, face: AgentKeyFace): void => {
  const badge = directionColor(face.subLabel);
  roundedPath(context, 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE, KEY_RADIUS);
  context.fillStyle = face.selected ? badge : "#15181d";
  context.fill();

  const inner = KEY_IMAGE_SIZE - FACE_INSET * 2;
  roundedPath(context, FACE_INSET, FACE_INSET, inner, inner, FACE_RADIUS);
  context.fillStyle = createPaint(
    context,
    face.selected ? "linear-gradient(180deg,#39445a,#232a3a)" : "linear-gradient(180deg,#171a20,#0f1216)",
    FACE_INSET,
    FACE_INSET,
    inner,
    inner,
  );
  context.fill();

  // Three signals rather than one, because a gradient shift alone was not
  // legible at arm's length and the operator could not tell which key he was
  // reading: a full-height rail in the badge colour down the left edge, an
  // inverted badge chip, and the brighter face above.
  if (face.selected) {
    roundedPath(context, FACE_INSET, FACE_INSET, SELECTION_RAIL, inner, SELECTION_RAIL / 2);
    context.fillStyle = badge;
    context.fill();
  }

  const badgeText = face.subLabel.toUpperCase();
  context.font = "700 11px monospace";
  if (face.selected) {
    const chipWidth = context.measureText(badgeText).width + 10;
    roundedPath(context, PAD_X, 13, chipWidth, TAG_HEIGHT, TAG_HEIGHT / 2);
    context.fillStyle = badge;
    context.fill();
    context.fillStyle = "#0f1216";
    context.fillText(badgeText, PAD_X + 5, 24);
  } else {
    context.fillStyle = badge;
    context.fillText(badgeText, PAD_X, 24);
  }

  context.font = "600 13px sans-serif";
  context.fillStyle = face.selected ? TEXT_PRIMARY : TEXT_TITLE;
  // One line fewer when a timestamp occupies the bottom strip, so the text
  // cannot run underneath it.
  const textLines = face.timeLabel === "" ? 4 : 3;
  wrapToWidth(context, face.title, KEY_IMAGE_SIZE - PAD_X * 2, textLines).forEach((line, index) => {
    context.fillText(line, PAD_X, 44 + index * 15);
  });

  if (face.timeLabel !== "") {
    context.font = "700 10px monospace";
    context.fillStyle = "rgba(255,255,255,0.5)";
    context.textAlign = "right";
    context.fillText(face.timeLabel, KEY_IMAGE_SIZE - PAD_X, KEY_IMAGE_SIZE - 9);
    context.textAlign = "left";
  }
};

const drawKey = (canvas: Canvas, face: KeyFace): void => {
  const context = canvas.getContext("2d");
  if (face.kind === "empty") {
    context.fillStyle = EMPTY_FILL;
    context.fillRect(0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE);
    return;
  }
  if (face.role === "command") {
    drawCommandKey(context, face);
    return;
  }
  if (face.role === "live") {
    drawLiveKey(context, face);
    return;
  }
  if (face.role === "event") {
    drawEventKey(context, face);
    return;
  }
  drawKeyPlate(context, face);
  drawKeyHeader(context, face);
  drawKeyTitle(context, face);
  drawKeyFooter(context, face);
};

const drawSegment = (canvas: Canvas, content: SegmentContent, width: number): void => {
  drawSegmentContent(canvas.getContext("2d"), content, width);
};

/**
 * Cap on the encoded-image cache.
 *
 * The cache is keyed by content, and the strip's content is now unbounded: a
 * full-width chat readout is a different image for every scroll position of
 * every agent's transcript, at 800x100 rather than 200x100. Left uncapped, a
 * long-running sidecar accumulates one JPEG per distinct window it has ever
 * shown. Least-recently-used eviction keeps the working set — the current
 * mode's panels and the visible keys — resident, which is where every hit
 * comes from anyway.
 */
const IMAGE_CACHE_LIMIT = 512;

export const createRasterizer = (options: RasterizerOptions = {}) => {
  const jpegQuality = quality(options.jpegQuality);
  const cache = new Map<string, Uint8Array>();
  const encode = (canvas: Canvas): Uint8Array => Uint8Array.from(canvas.toBuffer("image/jpeg", jpegQuality));

  /** Cached bytes, promoted to most-recently-used, or undefined on a miss. */
  const recall = (cacheKey: string): Uint8Array | undefined => {
    const cached = cache.get(cacheKey);
    if (cached === undefined) return undefined;
    cache.delete(cacheKey);
    cache.set(cacheKey, cached);
    return cached;
  };

  const remember = (cacheKey: string, encoded: Uint8Array): Uint8Array => {
    cache.set(cacheKey, encoded);
    // Map iteration is insertion-ordered and `recall` re-inserts on a hit, so
    // the first key is the least recently used.
    while (cache.size > IMAGE_CACHE_LIMIT) cache.delete(cache.keys().next().value as string);
    return encoded;
  };

  return {
    key: (descriptor: KeyDescriptor): Uint8Array => {
      const cacheKey = `key:${JSON.stringify(descriptor)}`;
      const cached = recall(cacheKey);
      if (cached !== undefined) return cached.slice();
      const canvas = createCanvas(KEY_IMAGE_SIZE, KEY_IMAGE_SIZE);
      drawKey(canvas, composeKeyFace(descriptor));
      return remember(cacheKey, encode(canvas)).slice();
    },
    /**
     * Encodes one strip panel. `width` is the panel's own width — 200 for a
     * grid-mode segment, 400 for the merged provider area, 800 for the cmd and
     * logs readouts — and is part of the cache key, because the same content at
     * a different width is a different image.
     */
    segment: (content: SegmentContent, width: number = SEGMENT_WIDTH): Uint8Array => {
      // The chat readout is deliberately not cached.
      //
      // Its content changes every frame while a message is being revealed, so
      // every lookup is a guaranteed miss followed by an insert. Left in the
      // shared LRU, one reveal evicts every cached key face and leaves the map
      // full of 800x100 JPEGs that can never be hit again — the cache did not
      // merely fail to help, it actively threw away the entries that were
      // working.
      if (content.kind === "chatLog") {
        const canvas = createCanvas(width, SEGMENT_HEIGHT);
        drawSegment(canvas, content, width);
        return encode(canvas);
      }
      // The minute is part of the identity. A panel's content can be unchanged
      // while the pixels are not: `resetLabel` and `ageLabel` render relative
      // times off `Date.now()`, so a cache keyed on content alone would freeze
      // "3m" on the strip while the event key beside it ticked to "31m", and an
      // eviction would silently re-encode the same content into different
      // bytes — which is exactly what `StripRenderer` promises never happens.
      // Both labels are minute-resolution, so a minute bucket is the finest
      // grain that can change anything.
      const cacheKey = `segment:${width}:${Math.floor(Date.now() / 60_000)}:${JSON.stringify(content)}`;
      const cached = recall(cacheKey);
      if (cached !== undefined) return cached.slice();
      const canvas = createCanvas(width, SEGMENT_HEIGHT);
      drawSegment(canvas, content, width);
      return remember(cacheKey, encode(canvas)).slice();
    },
  };
};

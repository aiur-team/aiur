/** Key face drawing: the canvas painters behind the rasteriser's `key` images. */
import { type Canvas, type SKRSContext2D } from "@napi-rs/canvas";
import { type AgentKeyFace, type KeyFace } from "./keys/keyFace.js";
import { KEY_IMAGE_SIZE } from "./keys/keyImage.js";
import { createPaint } from "./art/gradient.js";
import { commandFragment, commandIsFilled, drawIcon, iconFragment, UNBLOCKED_ICON } from "./art/icons.js";
import { KEY_FACE_CONTRACT } from "./key-face-contract.js";
import { drawVendorMark } from "./art/vendorMark.js";

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
/**
 * Open-padlock glyph on an unblocked queued key, sized to the tag band it
 * replaces so the footer keeps the same two-row height either way.
 */
const UNBLOCKED_ICON_SIZE = 15;
/** Width of the left rail that marks the active event key. */
const SELECTION_RAIL = 5;

const EMPTY_FILL = "#0a0b0d";
const TEXT_PRIMARY = "#f1f3f6";
const TEXT_TITLE = "rgba(240,242,246,0.92)";
const CHIP_FILL = "rgba(255,255,255,0.08)";
const CHIP_BORDER = "rgba(255,255,255,0.12)";
const BAR_TRACK = "rgba(255,255,255,0.14)";
/** Ink for the unblocked padlock glyph; the ready pill it replaced used the same green. */
const TAG_READY_TEXT = "#88e0a6";
const TAG_BLOCKED_FILL = "rgba(224,86,78,0.2)";
const TAG_BLOCKED_TEXT = "#ff9a90";

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
 * A queued key's footer is two stacked rows (status label above the blocked
 * pill, or above the unblocked glyph) where every other state's is a single
 * row, so a queued title gets one line fewer. Without that the third line runs
 * straight through the status label.
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

/** Status dot plus single-colour bar, or the queued status label and tag. */
const drawKeyFooter = (context: SKRSContext2D, face: AgentKeyFace): void => {
  if (face.footer.kind === "queued") {
    // Two stacked rows (the mock's `.sd-ag-foot.col`): status label above, the
    // dependency state below it. They must not share a baseline band.
    context.font = `700 11px sans-serif`;
    context.fillStyle = face.accent;
    context.fillText(face.footer.label, PAD_X, FOOTER_BASE - TAG_HEIGHT - 5);

    const tagTop = FOOTER_BASE - TAG_HEIGHT;

    // Unblocked is a glyph in the bottom-right corner rather than a pill.
    // `statusLabel` stays on the descriptor -- the emulator and the parity
    // vectors still carry the word -- but a key that is ready to start says so
    // with the open padlock, which reads at a glance where a second pill of
    // small caps did not.
    if (face.footer.unblocked) {
      drawIcon(
        context,
        UNBLOCKED_ICON,
        KEY_IMAGE_SIZE - PAD_X - UNBLOCKED_ICON_SIZE,
        FOOTER_BASE - UNBLOCKED_ICON_SIZE,
        UNBLOCKED_ICON_SIZE,
        TAG_READY_TEXT,
      );
      return;
    }

    const tag = face.footer.statusLabel;
    context.font = `700 9px monospace`;
    const tagWidth = context.measureText(tag).width + 10;
    roundedPath(context, PAD_X, tagTop, tagWidth, TAG_HEIGHT, TAG_HEIGHT / 2);
    context.fillStyle = TAG_BLOCKED_FILL;
    context.fill();
    context.fillStyle = TAG_BLOCKED_TEXT;
    context.fillText(tag, PAD_X + 5, tagTop + TAG_HEIGHT - 3.5);
    return;
  }

  const dotY = FOOTER_BASE - DOT_SIZE;
  const unknown = face.footer.percent === null;
  context.beginPath();
  context.arc(PAD_X + DOT_SIZE / 2, dotY + DOT_SIZE / 2, DOT_SIZE / 2, 0, Math.PI * 2);
  context.fillStyle = unknown ? face.footer.barColor : face.accent;
  context.fill();

  const barX = PAD_X + DOT_SIZE + 7;
  const barWidth = KEY_IMAGE_SIZE - PAD_X - barX;
  const barY = dotY + (DOT_SIZE - BAR_HEIGHT) / 2;
  roundedPath(context, barX, barY, barWidth, BAR_HEIGHT, BAR_HEIGHT / 2);
  context.fillStyle = unknown ? face.footer.barColor : BAR_TRACK;
  context.fill();

  // Unknown fills the whole track with one neutral grey. A measured 0% below
  // remains a short green stub, so the two states stay distinct without shape.
  if (unknown) return;

  // `Math.max(..., BAR_HEIGHT)` deliberately applies at 0 as well: a known 0%
  // paints a visible stub. Skipping the fill there is what made "just started"
  // and "no reading" the same picture.
  const filled = Math.max(Math.round((barWidth * face.footer.percent) / 100), BAR_HEIGHT);
  roundedPath(context, barX, barY, filled, BAR_HEIGHT, BAR_HEIGHT / 2);
  context.fillStyle = face.footer.barColor;
  context.fill();
};

/**
 * A per-agent command key: one large centred glyph over a label and caption.
 * The mic key is the exception — while held it turns green, which is the only
 * feedback the operator has that the hold registered.
 */
const drawCommandKey = (context: SKRSContext2D, face: AgentKeyFace): void => {
  // The mic turns green while held — the only feedback the operator has that
  // the hold registered — and the Commands Approve key is permanently green
  // because it commits: a dial that silently does nothing and a green key that
  // sends must never read alike.
  const live = (face.icon === "mic" && face.subLabel.toUpperCase() === "LIVE") || face.icon === "approve";
  // The Commands key asks for attention while the focused agent owes an answer.
  // Read the same way `live` is read — from the face the descriptor composed —
  // and painted from the key-face contract's alert tokens the descriptor put on
  // it, so the deck has one amber for "needs input" instead of a second one
  // invented here.
  const attention = !live && face.icon === "alert" && face.subLabel.toUpperCase().endsWith("PENDING");
  roundedPath(context, 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE, KEY_RADIUS);
  context.fillStyle = live
    ? createPaint(context, "linear-gradient(180deg,#37d97e,#1f9c56)", 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE)
    : attention
    ? createPaint(context, face.glow, 0, 0, KEY_IMAGE_SIZE, KEY_IMAGE_SIZE)
    : "#1b1e25";
  context.fill();

  const inner = KEY_IMAGE_SIZE - FACE_INSET * 2;
  roundedPath(context, FACE_INSET, FACE_INSET, inner, inner, FACE_RADIUS);
  context.fillStyle = createPaint(
    context,
    live ? "linear-gradient(180deg,#17402a,#0f1a13)" : attention ? face.face : "linear-gradient(180deg,#1a1d24,#111318)",
    FACE_INSET,
    FACE_INSET,
    inner,
    inner,
  );
  context.fill();

  const glyph = 38;
  drawIcon(
    context,
    // The warning triangle is a lane glyph, not a command glyph: the Commands
    // key reuses the deck's one triangle rather than a second copy in the
    // command set, and `commandFragment` would fall back to the log bars for it.
    face.icon === "alert" ? iconFragment(face.icon) : commandFragment(face.icon),
    (KEY_IMAGE_SIZE - glyph) / 2,
    26,
    glyph,
    live ? "#eafff3" : attention ? face.accent : "#ffffff",
    // A pending key fills the triangle: at arm's length a solid shape is the
    // difference the operator sees before they can read the caption.
    commandIsFilled(face.icon) || attention,
  );

  context.textAlign = "center";
  context.font = "700 15px sans-serif";
  context.fillStyle = live ? "#eafff3" : attention ? face.accent : TEXT_PRIMARY;
  context.fillText(face.title, KEY_IMAGE_SIZE / 2, 88);
  if (face.subLabel !== "") {
    context.font = "700 9px monospace";
    context.fillStyle = live ? "rgba(234,255,243,0.85)" : attention ? face.accent : "rgba(240,242,246,0.55)";
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

export const drawKey = (canvas: Canvas, face: KeyFace): void => {
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

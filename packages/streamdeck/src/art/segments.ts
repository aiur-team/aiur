/**
 * Touch-strip panel painting.
 *
 * The Plus strip is one 800x100 LCD. Most of the time the sidecar treats it as
 * four independently repaintable 200x100 regions, but a panel is whatever
 * rectangle `stripLayout` gave it — 200 wide for a provider meter, 400 for the
 * merged provider area, 800 for the cmd and logs readouts. Every routine here
 * therefore takes its width rather than assuming 200; nothing in this module
 * knows how many panels the strip currently has.
 *
 * Two parity points that a naive rendering gets wrong:
 *
 *   - a provider segment's reading is a *window*, and `hasData` distinguishes
 *     "no reading yet" from "zero usage". Showing "0%" for a meter that has not
 *     reported reads as headroom the fleet may not have.
 *   - consumption bars are deliberately NOT hue-mapped the way agent progress
 *     is; see {@link MINI_BAR_FILL}.
 */
import type { SKRSContext2D } from "@napi-rs/canvas";

import { rowKindOfRole, type ChatKind, type DiffLine, type TranscriptRow } from "../channel.js";
import type { SegmentContent } from "../touchStrip/stripLayout.js";
import { encoderCenterX } from "../touchStrip/geometry.js";
import { PROVIDER_SCROLL_ENCODER, VISIBLE_PROVIDER_ROWS, type ProviderPanelRow } from "../touchStrip/providerPanel.js";
import {
  BADGE_IDS,
  bucketContract,
  directionBadgeColor,
  KEY_FACE_CONTRACT,
  progressBarColor,
  type BucketContract,
  type BucketId,
  type DirectionBadge,
} from "../key-face-contract.js";
import { createPaint } from "./gradient.js";
import { activityFragment, drawIcon, iconFragment } from "./icons.js";
import { drawBrandMark, drawVendorMark } from "./vendorMark.js";

const BG = "#0f1216";
const DIVIDER = "rgba(255,255,255,0.10)";
const LABEL = "rgba(255,255,255,0.55)";
const TEXT = "#f1f3f6";
const MUTED = "rgba(240,242,246,0.72)";
const TRACK = "rgba(255,255,255,0.14)";
const ACCENT_LIVE = "#4ade80";
const DOT_ON = "#f1f3f6";
const DOT_OFF = "rgba(255,255,255,0.28)";
const CHIP_FILL = "rgba(255,255,255,0.08)";
const CHIP_BORDER = "rgba(255,255,255,0.12)";
/** Dashed track for a progress reading nobody took; matches the key face. */
const UNKNOWN_METER = "rgba(255,255,255,0.22)";

const PAD = 12;
const METER_HEIGHT = 8;
/** Full strip height; every panel is full height. */
const HEIGHT = 100;

/*
 * Shared vertical grid for the 200-wide grid-mode panels. All four are read as
 * one strip, so the title, the value row and the bar must land on the same
 * baselines with the same bottom margin — otherwise the bars visibly stagger.
 */
/** Title baseline: "SUMMARY", a provider name, the agent count. */
const TITLE_BASELINE = 30;
/** Font shared by every panel title. */
const TITLE_FONT = "700 18px sans-serif";
/** Baseline for the label/value row above the bar. */
const VALUE_BASELINE = 68;
/** Top of the bar; 100 - BAR_TOP - METER_HEIGHT is the bottom margin. */
const BAR_TOP = 76;

/** Type size the event keys use for event text, shared by the chat readout. */
const EVENT_TEXT_SIZE = 13;

const clamp = (value: number, low: number, high: number): number => Math.max(low, Math.min(high, value));

/** Small uppercase caption used for panel headings. */
const caption = (context: SKRSContext2D, text: string, x: number, y: number, color = LABEL): void => {
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
const MINI_BAR_FILL = "linear-gradient(90deg,#3f8bff,#8fbcff)";

/** Builds the mini-bar gradient across the bar's own width. */
const miniBarFill = (context: SKRSContext2D, x: number, width: number): string | CanvasGradient =>
  createPaint(context, MINI_BAR_FILL, x, 0, width, METER_HEIGHT);

/** A rounded meter with a filled portion; `fraction` is clamped to 0..1. */
const meter = (
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

/** "Resets 22m" style caption from an ISO instant, relative to `now`. */
export const resetLabel = (resetsAt: string | null, now: number): string | null => {
  if (resetsAt === null) return null;
  const at = Date.parse(resetsAt);
  if (Number.isNaN(at)) return null;
  const minutes = Math.round((at - now) / 60_000);
  if (minutes <= 0) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours}h ${minutes % 60}m` : `${Math.floor(hours / 24)}d`;
};

/**
 * "3m" style age from a past ISO instant, relative to `now`.
 *
 * The key faces carry a relative age computed by the daemon, but a transcript
 * header carries the raw timestamp, so the strip derives its own. Mirrors
 * {@link resetLabel}, which faces the other way in time.
 */
export const ageLabel = (timestamp: string | null, now: number): string | null => {
  if (timestamp === null) return null;
  const at = Date.parse(timestamp);
  if (Number.isNaN(at)) return null;
  const seconds = Math.max(0, Math.round((now - at) / 1000));
  if (seconds < 60) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86_400)}d`;
};

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
const fit = (context: SKRSContext2D, text: string, maxWidth: number): string => {
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
const rightText = (context: SKRSContext2D, text: string, right: number, y: number, color: string): number => {
  const width = context.measureText(text).width;
  context.fillStyle = color;
  context.fillText(text, right - width, y);
  return width;
};

/**
 * The bucket contract for a status, or null when the daemon sent one the
 * contract does not define. `bucketContract` throws on an unknown state, which
 * is right where the state came from the compile-time-checked key path, but the
 * cmd panel's status is a free string off the wire — a repaint must not die
 * because a new bucket appeared server-side first.
 */
const knownBucket = (status: string): BucketContract | null =>
  Object.hasOwn(KEY_FACE_CONTRACT.states, status) ? bucketContract(status as BucketId) : null;

/** Provider name as the strip prints it: "claude" -> "Claude". */
const providerTitle = (label: string): string => label.charAt(0).toUpperCase() + label.slice(1);

/** Panel 1 in grid mode: live count plus the build mini-bar. */
const drawSummary = (context: SKRSContext2D, width: number, model: SegmentContent & { kind: "summary" }): void => {
  const mark = 20;
  drawBrandMark(context, PAD, TITLE_BASELINE - mark + 4, mark);
  context.font = TITLE_FONT;
  context.fillStyle = TEXT;
  context.fillText("Summary", PAD + mark + 7, TITLE_BASELINE);

  // Live count only, with its dot. The fleet total belongs to the pager panel,
  // which is where an operator looks to page through it.
  const live = `${model.model.live}`;
  context.font = "700 18px sans-serif";
  const liveWidth = context.measureText(live).width;
  context.fillStyle = TEXT;
  context.fillText(live, width - PAD - liveWidth, TITLE_BASELINE);
  context.beginPath();
  context.arc(width - PAD - liveWidth - 11, TITLE_BASELINE - 6, 4.5, 0, Math.PI * 2);
  context.fillStyle = ACCENT_LIVE;
  context.fill();

  const build = model.model.build;
  if (build === null) {
    context.font = "700 13px sans-serif";
    context.fillStyle = LABEL;
    context.fillText("No build order", PAD, VALUE_BASELINE);
    return;
  }
  const percent = Math.round(build.fraction * 100);
  context.font = "700 13px sans-serif";
  context.fillStyle = MUTED;
  context.fillText(`Build ${percent}%`, PAD, VALUE_BASELINE);
  if (build.etaLabel !== null) {
    rightText(context, `ETA ${build.etaLabel}`, width - PAD, VALUE_BASELINE, LABEL);
  }
  meter(context, PAD, BAR_TOP, width - PAD * 2, build.fraction, miniBarFill(context, PAD, width - PAD * 2));
};

/**
 * The session reading a provider row prints on its right, or the reason there
 * isn't one. Both callers show the same words for the same three states, so a
 * two-provider fleet and a five-provider fleet never disagree about what
 * "Awaiting data" means.
 */
const sessionReading = (row: ProviderPanelRow, now: number): { readonly text: string; readonly fraction: number | null } => {
  if (!row.model.hasData) return { text: "Awaiting data", fraction: null };
  const window = row.model.session;
  if (window === null) return { text: "No session window", fraction: null };
  const percent = Math.round(window.usedPercent);
  const reset = resetLabel(window.resetsAt, now);
  return { text: reset === null ? `Session ${percent}%` : `Session ${percent}% · ${reset}`, fraction: percent / 100 };
};

/**
 * Panels 2-3 in grid mode, when exactly two providers are configured: one
 * provider's session meter in its own 200x100 segment.
 *
 * The mock stacks a session and a weekly meter here. At 200x100 on a device
 * read from arm's length that made six lines of sub-11px type, so by operator
 * decision this shows the session window only, at roughly double the type size.
 * Weekly is still projected and available if it earns its space back.
 */
const drawProvider = (context: SKRSContext2D, width: number, row: ProviderPanelRow, now: number): void => {
  const mark = 22;
  drawVendorMark(context, row.label, PAD, TITLE_BASELINE - mark + 4, mark);
  context.font = TITLE_FONT;
  context.fillStyle = TEXT;
  context.fillText(providerTitle(row.label), PAD + mark + 8, TITLE_BASELINE);

  const reading = sessionReading(row, now);
  context.font = "700 13px sans-serif";
  if (reading.fraction === null) {
    context.fillStyle = LABEL;
    context.fillText(reading.text, PAD, VALUE_BASELINE);
    return;
  }

  context.fillStyle = LABEL;
  context.fillText("Session", PAD, VALUE_BASELINE);
  // The "Session" word is already the row label here, so the right-hand run
  // carries only the numbers.
  rightText(context, reading.text.replace("Session ", ""), width - PAD, VALUE_BASELINE, MUTED);
  meter(context, PAD, BAR_TOP, width - PAD * 2, reading.fraction, miniBarFill(context, PAD, width - PAD * 2));
};

/*
 * Fixed geometry for the merged provider panel. Every value is a constant
 * rather than a fraction of the row count: deriving them shrank the whole panel
 * as providers were configured, so the fleet that most needed reading was the
 * one printed smallest. Three rows of 28px fit 100px with a band left over for
 * the scroll label; see VISIBLE_PROVIDER_ROWS.
 */
const PROVIDER_ROW_TOP = 4;
const PROVIDER_ROW_HEIGHT = 28;
const PROVIDER_ROW_FONT = 13;
const PROVIDER_ROW_BAR = 6;
const PROVIDER_ROW_MARK = 20;
/**
 * Where the rows stop and the scroll label's band begins.
 *
 * Derived from the window size rather than written out, so raising
 * {@link VISIBLE_PROVIDER_ROWS} shows up as a band that no longer fits inside
 * the panel — a test asserts it does — instead of as a fourth row the canvas
 * quietly clips, which is the silent drop this whole feature removes.
 */
export const PROVIDER_SCROLL_BAND_TOP = PROVIDER_ROW_TOP + VISIBLE_PROVIDER_ROWS * PROVIDER_ROW_HEIGHT;
/** Baseline of the scroll label, in the bottom band nearest the knobs. */
const PROVIDER_SCROLL_BASELINE = HEIGHT - 3;
/** Half-width and height of one scroll chevron. */
const CHEVRON = 4;
/** Space between a chevron and the label between them. */
const CHEVRON_GAP = 6;

/**
 * A solid triangle pointing up or down, centred on `x`.
 *
 * Drawn rather than typed: the strip renders through fontconfig on whatever
 * host the sidecar runs on, and an arrow glyph that resolves to tofu there
 * would turn the one control hint on this panel into a box.
 */
const chevron = (context: SKRSContext2D, x: number, y: number, up: boolean, color: string): void => {
  const tip = up ? y - CHEVRON : y + CHEVRON;
  context.beginPath();
  context.moveTo(x, tip);
  context.lineTo(x - CHEVRON, y + (up ? CHEVRON : -CHEVRON));
  context.lineTo(x + CHEVRON, y + (up ? CHEVRON : -CHEVRON));
  context.closePath();
  context.fillStyle = color;
  context.fill();
};

/**
 * The scroll affordance: how many providers there are, and which way knob 2
 * still has somewhere to go.
 *
 * Centred over knob 2 rather than over this panel, because the panel starts at
 * the strip's quarter mark and its centre is the gap between knobs 2 and 3 —
 * a hint centred there names neither knob. `originX` comes from the layout, so
 * moving the panel moves the label with it. Each chevron is lit only while
 * there are rows in that direction, so at the top of the list the label itself
 * says the list is at its top.
 *
 * Lit is DOT_ON, the pager's own on/off pair, and deliberately not the live
 * accent: green means "healthy" on this surface, and a green pip 4px under a
 * column of quota meters reads as headroom — the same confusion
 * {@link MINI_BAR_FILL} refuses the hue map for.
 */
const drawProviderScroll = (context: SKRSContext2D, content: SegmentContent & { kind: "providers" }): void => {
  const { model } = content;
  const label = `${model.total} MODELS`;
  context.font = "700 10px monospace";
  const blockWidth = context.measureText(label).width + (CHEVRON * 2 + CHEVRON_GAP) * 2;
  const left = encoderCenterX(PROVIDER_SCROLL_ENCODER) - content.originX - blockWidth / 2;
  const middle = (PROVIDER_SCROLL_BASELINE + PROVIDER_SCROLL_BAND_TOP) / 2;

  chevron(context, left + CHEVRON, middle, true, model.hasAbove ? DOT_ON : DOT_OFF);
  context.fillStyle = LABEL;
  context.fillText(label, left + CHEVRON * 2 + CHEVRON_GAP, PROVIDER_SCROLL_BASELINE);
  chevron(context, left + blockWidth - CHEVRON, middle, false, model.hasBelow ? DOT_ON : DOT_OFF);
};

/**
 * The merged 400x100 provider area, used from three providers up.
 *
 * One row per visible provider: its mark in a left column, its name and session
 * reading on a text line, and a bar spanning the rest of the area under both of
 * the segments this panel replaced. The window is at most
 * {@link VISIBLE_PROVIDER_ROWS} rows and every row is the same size whatever the
 * fleet runs; when more providers are configured than that, knob 2 scrolls and
 * the bottom band says so.
 */
const drawProviders = (context: SKRSContext2D, width: number, content: SegmentContent & { kind: "providers" }, now: number): void => {
  const { model } = content;
  const textX = PAD + PROVIDER_ROW_MARK + 6;
  const right = width - PAD;

  model.rows.forEach((row, index) => {
    const rowTop = PROVIDER_ROW_TOP + index * PROVIDER_ROW_HEIGHT;
    const baseline = rowTop + PROVIDER_ROW_FONT + 1;
    drawVendorMark(context, row.label, PAD, rowTop + (PROVIDER_ROW_HEIGHT - PROVIDER_ROW_BAR - PROVIDER_ROW_MARK) / 2, PROVIDER_ROW_MARK);

    const reading = sessionReading(row, now);
    context.font = `700 ${PROVIDER_ROW_FONT}px sans-serif`;
    const readingWidth = rightText(context, reading.text, right, baseline, reading.fraction === null ? LABEL : MUTED);
    context.fillStyle = TEXT;
    context.fillText(fit(context, providerTitle(row.label), right - textX - readingWidth - 8), textX, baseline);

    const barTop = rowTop + PROVIDER_ROW_HEIGHT - PROVIDER_ROW_BAR - 3;
    // A provider with no reading gets no bar at all. An empty track would read
    // as a real 0%, which is the exact confusion `hasData` exists to prevent.
    if (reading.fraction !== null) {
      meter(context, textX, barTop, right - textX, reading.fraction, miniBarFill(context, textX, right - textX), PROVIDER_ROW_BAR);
    }
  });

  // No affordance when the whole fleet is already on screen: a chevron pair
  // that cannot move is an instruction to turn a knob that does nothing.
  if (model.hasAbove || model.hasBelow) drawProviderScroll(context, content);
};

/**
 * Panel 4 in grid mode: the window pager.
 *
 * The agent count lives on the summary panel, so it is not repeated here. The
 * title carries the same weight as the others so the strip reads as one row,
 * and the dots sit on the shared bar line.
 */
const drawPager = (context: SKRSContext2D, width: number, content: SegmentContent & { kind: "pager" }): void => {
  context.font = TITLE_FONT;
  context.fillStyle = TEXT;
  context.fillText(content.label, (width - context.measureText(content.label).width) / 2, TITLE_BASELINE);

  const dots = content.model.dots;
  const spacing = 16;
  const startX = (width - (dots.length - 1) * spacing) / 2;
  dots.forEach((filled, index) => {
    context.beginPath();
    context.arc(startX + index * spacing, BAR_TOP + METER_HEIGHT / 2, 4.5, 0, Math.PI * 2);
    context.fillStyle = filled ? DOT_ON : DOT_OFF;
    context.fill();
  });
};

const isBadge = (badge: string): badge is DirectionBadge => (BADGE_IDS as readonly string[]).includes(badge);

/**
 * Contract colour for a badge the daemon sent.
 *
 * The badge crosses the wire as a free string, so an unrecognised one falls
 * back to INFO — the neutral badge — rather than throwing and taking the whole
 * strip repaint with it.
 */
const badgeColour = (badge: string): string => directionBadgeColor(isBadge(badge) ? badge : "INFO");

/*
 * ---------------------------------------------------------------------------
 * The logs-mode transcript, in opencode's grammar.
 * ---------------------------------------------------------------------------
 *
 * The readout mimics the opencode TUI's transcript rather than printing a
 * right-aligned role word in a gutter. The single most important thing it
 * borrows is the *absence* of a label: opencode never prints "ASSISTANT:", it
 * carries speaker identity in layout — assistant prose is bare indented text on
 * the page background, and everything that is not assistant prose earns a
 * glyph, a fill, or a bar. A label-free row is therefore the agent talking.
 *
 * COLOURS ARE BORROWED, NOT INVENTED. Every hex in {@link OPENCODE} is taken
 * from opencode's default `opencode` theme. They deliberately do NOT come from
 * `key-face-contract.json`: that contract is Aiur's *fleet-state* palette —
 * bucket accents and direction badges, shared with the dashboard so the two
 * surfaces cannot disagree about what "stuck" looks like. This is a different
 * palette on purpose, quoting another tool's transcript, and mixing the two
 * would make a fleet-state colour mean "removed line" somewhere on the strip.
 * The one exception is the event badge, which stays a direction-badge colour
 * because the badge is Aiur's own concept and the log keys paint the same token.
 */
const OPENCODE = {
  /** `text` / `markdownText`: assistant prose, command text, diff line text. */
  text: "#eeeeee",
  /** `textMuted`: completed tool calls, block titles, system chatter, the age. */
  textMuted: "#808080",
  /** `backgroundPanel`: the fill behind a user turn, a command, a tool block. */
  backgroundPanel: "#141414",
  /** `secondary`: the default agent colour, i.e. the user turn's `┃` bar. */
  secondary: "#5c9cf5",
  /** `error`: a failed tool call. The feed carries no failure flag yet. */
  error: "#e06c75",
  /** `diffAddedBg` / `diffRemovedBg`: full-row fills behind a unified diff line. */
  diffAddedBg: "#20303b",
  diffRemovedBg: "#37222c",
  /** `diffHighlightAdded` / `diffHighlightRemoved`: the `+`/`-` sign glyphs. */
  diffHighlightAdded: "#b8db87",
  diffHighlightRemoved: "#e26a75",
  /** opencode fades reasoning against its own prose; same layout, less ink. */
  reasoning: "rgba(238,238,238,0.55)",
} as const;

/** Row background per diff sign; context lines get the plain panel fill. */
const DIFF_ROW_FILL: Readonly<Record<DiffLine["sign"], string>> = {
  "+": OPENCODE.diffAddedBg,
  "-": OPENCODE.diffRemovedBg,
  " ": OPENCODE.backgroundPanel,
};

/** Sign-glyph tint per diff sign, brighter than the row fill it sits on. */
const DIFF_SIGN_COLOR: Readonly<Record<DiffLine["sign"], string>> = {
  "+": OPENCODE.diffHighlightAdded,
  "-": OPENCODE.diffHighlightRemoved,
  " ": OPENCODE.textMuted,
};

/**
 * Tool glyphs, opencode's two-column gutter. A tool the map does not name gets
 * the generic gear rather than a guessed glyph.
 */
const TOOL_GLYPHS: Readonly<Record<string, string>> = {
  bash: "$",
  shell: "$",
  run: "$",
  read: "→",
  view: "→",
  edit: "←",
  write: "←",
  patch: "←",
  glob: "✱",
  grep: "✱",
  search: "✱",
  webfetch: "%",
  fetch: "%",
};

/**
 * Glyphs for the roles opencode has no equivalent for. They exist only so a
 * system line, an alert or a CI report cannot be mistaken for assistant prose,
 * which on this surface is defined as the row with nothing in its gutter.
 */
const ROLE_GLYPHS: Readonly<Record<string, string>> = {
  system: "·",
  alert: "!",
  ci: "✓",
};

/**
 * Per-kind row colours, #1960: commands and tool rows are one class, agent
 * prose another, and system/reasoning/alert rows the third. The palette is the
 * emulator's existing logs palette (#1934, borrowed from opencode's default
 * theme and documented there) so the physical deck and the emulator agree —
 * and so the low-contrast hues of the plain opencode `text`/`textMuted`
 * inks do not wash out on a small backlit LCD.
 */
const CHAT_COLOURS: Readonly<Record<ChatKind, string>> = {
  command: "#88e0a6",
  agent: "#9fd0ff",
  logs: "#ffcf87",
  user: "#c69bff",
};

/** Left gutter (glyph column), then the body column: opencode's `paddingLeft: 3`. */
const CHAT_GLYPH_X = PAD;
const CHAT_BODY_X = PAD + 22;
/** The user turn's `┃` bar, at the very left edge. */
const CHAT_BAR_X = 4;
const CHAT_BAR_WIDTH = 2;
/** Widest a badge token may draw before it is clipped. */
const CHAT_BADGE_MAX = 72;
/** First transcript baseline, and the step between rows. */
const CHAT_FIRST_BASELINE = 16;
const CHAT_LINE_HEIGHT = 16;
/** Baseline-to-row-top, so a full-row fill lands on the row it belongs to. */
const CHAT_ROW_RISE = 12;

const CHAT_BADGE_FONT = "700 10px monospace";
const CHAT_GLYPH_FONT = "700 12px monospace";
const CHAT_BODY_FONT = `600 ${EVENT_TEXT_SIZE}px sans-serif`;
const CHAT_MONO_FONT = `600 ${EVENT_TEXT_SIZE - 1}px monospace`;

/** The row's full-width background: a fill, a diff tint, or a tool block. */
const chatRowFill = (context: SKRSContext2D, width: number, baseline: number, color: string): void => {
  context.fillStyle = color;
  context.fillRect(0, baseline - CHAT_ROW_RISE, width, CHAT_LINE_HEIGHT);
};

/**
 * Draws one clipped run at `x` and reports the width it actually used, so the
 * next run starts after it instead of over it. A negative budget draws nothing
 * and advances by nothing.
 */
const runText = (context: SKRSContext2D, text: string, x: number, baseline: number, color: string, budget: number): number => {
  const clipped = fit(context, text, budget);
  context.fillStyle = color;
  context.fillText(clipped, x, baseline);
  return context.measureText(clipped).width;
};

/** Gutter glyph for a named tool; `⚙` for one the map does not know. */
const toolGlyph = (tool: string | null): string => TOOL_GLYPHS[(tool ?? "").toLowerCase().replace(/[_\-\s]/g, "")] ?? "⚙";

/** The sign a bare hunk string carries, for a feed that sent no `lines`. */
const signOf = (line: string): DiffLine["sign"] => (line.startsWith("+") ? "+" : line.startsWith("-") ? "-" : " ");

/**
 * An event header: the analogue of opencode's block title.
 *
 * The badge keeps its direction colour, then the human topic `label` in bright
 * text, then the `body` only when it says something the label did not — the
 * feed often sets both to the same string, and printing it twice reads as a
 * rendering fault. The age stays right-aligned and muted.
 */
const drawEventHeaderRow = (
  context: SKRSContext2D,
  row: TranscriptRow & { kind: "event_header" },
  width: number,
  baseline: number,
  now: number,
): void => {
  const right = width - PAD;
  context.font = CHAT_BADGE_FONT;
  const badgeWidth = runText(context, row.badge.toUpperCase(), PAD, baseline, badgeColour(row.badge), CHAT_BADGE_MAX);
  const age = ageLabel(row.timestamp, now);
  const ageWidth = age === null ? 0 : rightText(context, age, right, baseline, OPENCODE.textMuted) + 8;

  const labelX = PAD + badgeWidth + 8;
  context.font = `700 ${EVENT_TEXT_SIZE}px sans-serif`;
  const labelWidth = runText(context, row.label, labelX, baseline, OPENCODE.text, right - ageWidth - labelX);
  if (row.body !== row.label) {
    const bodyX = labelX + labelWidth + 8;
    context.font = CHAT_BODY_FONT;
    runText(context, row.body, bodyX, baseline, OPENCODE.textMuted, right - ageWidth - bodyX);
  }
};

/**
 * A message row, in opencode's speaker grammar, colour-coded by row class.
 *
 * Assistant prose is the case with no gutter token at all; every other role
 * takes a glyph, a fill or a bar so that "nothing in the gutter" stays a
 * reliable reading of "the agent is talking". #1960 adds the per-kind colour:
 * commands/tools green, agent prose blue, logs/system tan, the user purple —
 * the same `row_kind` the server projects, so the physical deck and the
 * emulator paint the same class with the same ink. The `row_kind`/`glyph`
 * fields come from the server; a row that carries neither derives both from
 * its role.
 */
const drawMessageRow = (context: SKRSContext2D, row: TranscriptRow & { kind: "message" }, width: number, baseline: number): void => {
  const right = width - PAD;
  const budget = right - CHAT_BODY_X;
  const kind = row.rowKind ?? rowKindOfRole(row.role);
  const colour = CHAT_COLOURS[kind];

  if (kind === "agent") {
    context.font = CHAT_BODY_FONT;
    runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
    return;
  }

  if (kind === "command") {
    if (row.role === "tool") {
      // The row shows the command or path, not the tool name: the server
      // already carried the argument in `body` (verb stripped) and the glyph
      // in `glyph`, so a tool row reads `→ lib/aiur.ex` rather than
      // `Read [path=lib/aiur.ex]`.
      context.font = CHAT_GLYPH_FONT;
      runText(context, row.glyph ?? toolGlyph(row.tool), CHAT_GLYPH_X, baseline, colour, CHAT_BODY_X - CHAT_GLYPH_X);
      context.font = CHAT_MONO_FONT;
      runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
      return;
    }
    // opencode gives bash no colour of its own: the `$` is the differentiator.
    chatRowFill(context, width, baseline, OPENCODE.backgroundPanel);
    context.font = CHAT_GLYPH_FONT;
    runText(context, "$", CHAT_GLYPH_X, baseline, colour, CHAT_BODY_X - CHAT_GLYPH_X);
    context.font = CHAT_MONO_FONT;
    runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
    return;
  }

  if (kind === "user") {
    chatRowFill(context, width, baseline, OPENCODE.backgroundPanel);
    context.fillStyle = OPENCODE.secondary;
    context.fillRect(CHAT_BAR_X, baseline - CHAT_ROW_RISE, CHAT_BAR_WIDTH, CHAT_LINE_HEIGHT);
    context.font = CHAT_BODY_FONT;
    runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
    return;
  }

  // logs: system/reasoning/alert/ci rows keep a role glyph so they are not
  // read as prose, but take the tan log colour like the emulator.
  context.font = CHAT_GLYPH_FONT;
  runText(context, ROLE_GLYPHS[row.role] ?? "·", CHAT_GLYPH_X, baseline, colour, CHAT_BODY_X - CHAT_GLYPH_X);
  context.font = CHAT_BODY_FONT;
  runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
};

/**
 * A diff row, unified — opencode only splits above 120 columns and this panel
 * is nowhere near that wide.
 *
 * ONE TranscriptRow IS ALWAYS ONE PAINTED ROW. The controller addresses
 * transcript rows by index to scroll and to jump the log keys, so a row that
 * painted three lines would move the readout three rows for one detent. The
 * *feed* therefore unrolls a hunk into a header row plus one `diff_line` row
 * each — the expansion happens where the indices are assigned, not here.
 *
 * This is the header: opencode's block title. Panel fill, a `┃` notch, the path
 * as a muted title, and the `+N -M` counts right-aligned. The counts are not an
 * opencode element (there they appear only on a revert banner) but the feed
 * carries them and they earn their space on this row — never on a row that is
 * itself a diff line.
 *
 * `line` is the fallback for a provider that gave a summary and no hunk: rather
 * than a header with nothing under it, the one line it did give rides here.
 *
 * There are no line numbers. opencode always shows them; our feed carries none,
 * and numbering the hunk's own offsets would print invented data on a
 * glanceable surface.
 */
const drawDiffRow = (context: SKRSContext2D, row: TranscriptRow & { kind: "diff" }, width: number, baseline: number): void => {
  const right = width - PAD;

  chatRowFill(context, width, baseline, OPENCODE.backgroundPanel);
  context.font = CHAT_GLYPH_FONT;
  runText(context, "┃", CHAT_GLYPH_X, baseline, OPENCODE.textMuted, CHAT_BODY_X - CHAT_GLYPH_X);

  context.font = CHAT_BADGE_FONT;
  const countsWidth = rightText(context, `+${row.additions} -${row.deletions}`, right, baseline, OPENCODE.textMuted) + 10;

  context.font = CHAT_MONO_FONT;
  const pathWidth = runText(context, row.path, CHAT_BODY_X, baseline, OPENCODE.textMuted, right - countsWidth - CHAT_BODY_X);
  const cursor = CHAT_BODY_X + pathWidth + 8;

  if (row.line !== null) {
    runText(context, row.line, cursor, baseline, DIFF_SIGN_COLOR[signOf(row.line)], right - countsWidth - cursor);
  }
};

/**
 * One line of the hunk: opencode's unified diff row.
 *
 * Full-row background fill by sign, the sign glyph in the brighter highlight
 * colour, and the line itself in the bright text colour — the three signals
 * opencode uses, at the one type size this strip has.
 */
const drawDiffLineRow = (context: SKRSContext2D, row: TranscriptRow & { kind: "diff_line" }, width: number, baseline: number): void => {
  chatRowFill(context, width, baseline, DIFF_ROW_FILL[row.sign]);
  context.font = CHAT_MONO_FONT;
  runText(context, row.sign === " " ? "·" : row.sign, CHAT_GLYPH_X, baseline, DIFF_SIGN_COLOR[row.sign], CHAT_BODY_X - CHAT_GLYPH_X);
  runText(context, row.text, CHAT_BODY_X, baseline, row.sign === " " ? OPENCODE.textMuted : OPENCODE.text, width - PAD - CHAT_BODY_X);
};

/** One transcript row as a single line of the chat readout. */
const drawChatRow = (context: SKRSContext2D, row: TranscriptRow, width: number, baseline: number, now: number): void => {
  if (row.kind === "event_header") return drawEventHeaderRow(context, row, width, baseline, now);
  if (row.kind === "diff") return drawDiffRow(context, row, width, baseline);
  if (row.kind === "diff_line") return drawDiffLineRow(context, row, width, baseline);
  return drawMessageRow(context, row, width, baseline);
};

/** A dial hint: the caption plus arrows that appear only where there is more. */
const drawHint = (
  context: SKRSContext2D,
  label: string,
  x: number,
  baseline: number,
  hasPrevious: boolean,
  hasNext: boolean,
): void => {
  const text = `${hasPrevious ? "‹" : " "} ${label} ${hasNext ? "›" : " "}`;
  context.font = "700 9px monospace";
  context.fillStyle = hasPrevious || hasNext ? ACCENT_LIVE : LABEL;
  context.fillText(text, x, baseline);
};

/**
 * logs mode as one continuous readout of the agent's chat log.
 *
 * Five rows at the event keys' own type size, and the two dial hints on a
 * bottom line: `CHAT` under dial A, which scrolls this view, and `EVENTS` under
 * dial D, which pages the keys. The arrows are state — they show only where
 * there is something further in that direction.
 */
const drawChatLog = (context: SKRSContext2D, width: number, content: SegmentContent & { kind: "chatLog" }, now: number): void => {
  if (content.rows.length === 0) {
    context.font = CHAT_BODY_FONT;
    context.fillStyle = OPENCODE.textMuted;
    context.fillText("No chat yet.", CHAT_BODY_X, CHAT_FIRST_BASELINE + CHAT_LINE_HEIGHT);
  }
  content.rows.forEach((row, index) => {
    drawChatRow(context, row, width, CHAT_FIRST_BASELINE + index * CHAT_LINE_HEIGHT, now);
  });
  drawHint(context, "CHAT", PAD, HEIGHT - 5, content.chatHasPrevious, content.chatHasNext);
  drawHint(context, "EVENTS", width * 0.75, HEIGHT - 5, content.eventHasPrevious, content.eventHasNext);
};

/**
 * cmd mode as one continuous readout of the focused agent.
 *
 * The left quarter is a summary column that mirrors the top of the agent's grid
 * key — epic icon, provider mark, ticket id — plus the BACK hint, which sits
 * under dial A because dial A is what performs it. The remaining three quarters
 * are one area, with no dividers: the full title, the activity, the elapsed
 * time, and a bar that runs the whole width because the progress it shows is
 * one number, not three.
 */
const drawAgentDetail = (context: SKRSContext2D, width: number, content: SegmentContent & { kind: "agentDetail" }, now: number): void => {
  void now;
  const { model } = content;
  const bucket = knownBucket(model.status);
  const accent = bucket?.accent ?? LABEL;
  const summaryWidth = width / 4;

  const chip = 26;
  context.beginPath();
  context.roundRect(PAD, 8, chip, chip, 8);
  context.fillStyle = CHIP_FILL;
  context.fill();
  context.strokeStyle = CHIP_BORDER;
  context.lineWidth = 1;
  context.stroke();
  drawIcon(context, iconFragment(model.icon), PAD + 4.5, 12.5, 17, accent);
  drawVendorMark(context, model.vendor, PAD + chip + 7, 11, 20);

  context.font = "700 26px monospace";
  context.fillStyle = TEXT;
  context.fillText(fit(context, model.ticketId, summaryWidth - PAD * 2), PAD, 66);
  drawHint(context, "BACK", PAD, HEIGHT - 6, true, false);

  const left = summaryWidth + 8;
  const right = width - PAD;

  // An em dash rather than "0%": the key face for this same ticket is one
  // press away painting a dashed no-reading track, and the two must not
  // contradict each other on the operator's screen.
  const percent = model.percent === null ? "—" : `${Math.round(model.percent)}%`;
  context.font = "700 22px sans-serif";
  const percentWidth = rightText(context, percent, right, 30, model.percent === null ? MUTED : TEXT);
  context.font = "700 21px sans-serif";
  context.fillStyle = TEXT;
  context.fillText(fit(context, model.title, right - left - percentWidth - 14), left, 30);

  let cursor = left;
  if (model.activity !== null) {
    drawIcon(context, activityFragment(model.activity.glyph), cursor, 46, 16, accent);
    cursor += 21;
    context.font = "700 14px sans-serif";
    context.fillStyle = TEXT;
    context.fillText(model.activity.label, cursor, 59);
    cursor += context.measureText(model.activity.label).width + 12;
  }
  // The elapsed run is measured first so the status — a free string off the
  // wire, which an unknown bucket passes through verbatim — gets a real budget
  // and cannot overprint it on this shared baseline.
  context.font = "700 10px monospace";
  const captionWidth = model.elapsedLabel === null ? 0 : context.measureText("ELAPSED").width;
  context.font = "700 12px monospace";
  const elapsedWidth = model.elapsedLabel === null ? 0 : context.measureText(model.elapsedLabel).width + captionWidth + 20;
  context.fillStyle = accent;
  context.fillText(fit(context, bucket?.label.toUpperCase() ?? model.status.toUpperCase(), right - elapsedWidth - cursor), cursor, 59);

  if (model.elapsedLabel !== null) {
    context.font = "700 12px monospace";
    rightText(context, model.elapsedLabel, right, 59, MUTED);
    caption(context, "elapsed", right - context.measureText(model.elapsedLabel).width - 8 - captionWidth, 59);
  }

  if (model.percent === null) {
    // The same dashed track the key face uses for a reading nobody took.
    context.strokeStyle = UNKNOWN_METER;
    context.lineWidth = 10;
    context.setLineDash([5, 6]);
    context.beginPath();
    context.moveTo(left + 3, 79);
    context.lineTo(right - 3, 79);
    context.stroke();
    context.setLineDash([]);
    context.lineWidth = 1;
    return;
  }
  // A measured 0% is a solid stub. The unknown branch above remains a dashed
  // track, so the strip makes the same no-reading/zero distinction as the key.
  meter(context, left, 74, right - left, model.percent / 100, progressBarColor(model.percent), 10, true, model.freshness === "stale" ? 0.5 : 1);
};

/** Renders one panel's content onto a `width` x 100 context. */
export const drawSegmentContent = (
  context: SKRSContext2D,
  content: SegmentContent,
  width: number,
  now: number = Date.now(),
): void => {
  context.fillStyle = BG;
  context.fillRect(0, 0, width, HEIGHT);
  context.strokeStyle = DIVIDER;
  context.lineWidth = 1;
  context.beginPath();
  context.moveTo(width - 0.5, 8);
  context.lineTo(width - 0.5, 92);
  context.stroke();

  switch (content.kind) {
    case "summary":
      return drawSummary(context, width, content);
    case "provider":
      return drawProvider(context, width, content.row, now);
    case "providers":
      return drawProviders(context, width, content, now);
    case "pager":
      return drawPager(context, width, content);
    case "agentDetail":
      return drawAgentDetail(context, width, content, now);
    case "chatLog":
      return drawChatLog(context, width, content, now);
    case "blank":
      // A panel with no provider configured for it. Bare background only: an
      // "Awaiting data" label here would claim a provider exists.
      return;
  }
};

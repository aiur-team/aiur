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

import type { TranscriptRow } from "../channel.js";
import type { SegmentContent } from "../touchStrip/stripLayout.js";
import type { ProviderPanelModel, ProviderPanelRow } from "../touchStrip/providerPanel.js";
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
 * Deliberately NOT the key's hue map. These bars show *consumption* — quota
 * used, build completed — and hue-mapping them would paint a provider at 100%
 * of its rate limit bright green, which reads as healthy when it means the
 * opposite. The hue map belongs to agent progress, where more really is better.
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
): void => {
  const clamped = clamp(fraction, 0, 1);
  context.beginPath();
  context.roundRect(x, y, width, height, height / 2);
  context.fillStyle = TRACK;
  context.fill();
  const filled = Math.round(width * clamped);
  if (filled > 0) {
    context.beginPath();
    context.roundRect(x, y, Math.max(filled, height), height, height / 2);
    context.fillStyle = color;
    context.fill();
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
  if (context.measureText(text).width <= maxWidth) return text;
  let clipped = text;
  while (clipped.length > 1 && context.measureText(`${clipped}…`).width > maxWidth) clipped = clipped.slice(0, -1);
  return `${clipped}…`;
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

/**
 * The merged 400x100 provider area, used from three providers up.
 *
 * One row per provider: its mark in a left column, its name and session reading
 * on a text line, and a bar spanning the rest of the area under both of the
 * segments this panel replaced. Row height, type size and bar height all fall
 * out of the row count, so three providers get a generous row and five get a
 * tight but complete one — the panel shrinks to fit rather than clipping.
 */
const drawProviders = (context: SKRSContext2D, width: number, model: ProviderPanelModel, now: number): void => {
  const top = 5;
  const usable = HEIGHT - top - 3;
  const lines = model.rows.length + (model.overflow > 0 ? 1 : 0);
  const rowHeight = usable / lines;
  const fontSize = clamp(Math.round(rowHeight * 0.42), 8, 13);
  const barHeight = clamp(Math.round(rowHeight * 0.22), 3, 8);
  const markSize = clamp(Math.round(rowHeight) - 8, 10, 20);
  const textX = PAD + markSize + 6;
  const right = width - PAD;

  model.rows.forEach((row, index) => {
    const rowTop = top + index * rowHeight;
    const baseline = rowTop + fontSize + 1;
    drawVendorMark(context, row.label, PAD, rowTop + (rowHeight - barHeight - markSize) / 2, markSize);

    const reading = sessionReading(row, now);
    context.font = `700 ${fontSize}px sans-serif`;
    const readingWidth = rightText(context, reading.text, right, baseline, reading.fraction === null ? LABEL : MUTED);
    context.fillStyle = TEXT;
    context.fillText(fit(context, providerTitle(row.label), right - textX - readingWidth - 8), textX, baseline);

    const barTop = rowTop + rowHeight - barHeight - 2;
    // A provider with no reading gets no bar at all. An empty track would read
    // as a real 0%, which is the exact confusion `hasData` exists to prevent.
    if (reading.fraction !== null) {
      meter(context, textX, barTop, right - textX, reading.fraction, miniBarFill(context, textX, right - textX), barHeight);
    }
  });

  if (model.overflow > 0) {
    const baseline = top + model.rows.length * rowHeight + fontSize + 1;
    caption(context, `+${model.overflow} more providers`, textX, baseline);
  }
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

/**
 * Speaker colours, expressed as the direction badge each role reads as.
 *
 * The mock keeps a separate `whoC` table for chat roles, but every colour in it
 * is already a direction-badge colour, so the roles are mapped onto the badges
 * instead of copying the hexes into a second table that could drift from the
 * key faces.
 */
const ROLE_BADGES: Readonly<Record<string, DirectionBadge>> = {
  assistant: "AGENT",
  agent: "AGENT",
  reasoning: "AGENT",
  tool: "SYSTEM",
  command: "SYSTEM",
  alert: "SYSTEM",
  system: "SYSTEM",
  ci: "CONSUME",
};

/** Additions reuse the CONSUME badge; deletions the `stuck` accent — the mock's own two diff colours. */
const DIFF_ADD = directionBadgeColor("CONSUME");
const DIFF_DEL = bucketContract("stuck").accent;

/** Left gutter the speaker/badge token is right-aligned into, then the body column. */
const CHAT_TOKEN_RIGHT = 84;
const CHAT_BODY_X = 94;
/** First transcript baseline, and the step between rows. */
const CHAT_FIRST_BASELINE = 16;
const CHAT_LINE_HEIGHT = 16;

/**
 * One transcript row as a single line of the chat readout.
 *
 * Every row shape gets the same three columns — a speaker/badge token, the
 * body, and a right-aligned annotation — so the log reads down the page like
 * the terminal it mirrors instead of as three unrelated box layouts.
 */
const drawChatRow = (context: SKRSContext2D, row: TranscriptRow, right: number, baseline: number, now: number): void => {
  const token = (text: string, color: string): void => {
    context.font = "700 10px monospace";
    const clipped = fit(context, text.toUpperCase(), CHAT_TOKEN_RIGHT - PAD);
    rightText(context, clipped, CHAT_TOKEN_RIGHT, baseline, color);
  };

  if (row.kind === "event_header") {
    token(row.badge, badgeColour(row.badge));
    const age = ageLabel(row.timestamp, now);
    context.font = "700 10px monospace";
    const ageWidth = age === null ? 0 : rightText(context, age, right, baseline, LABEL) + 8;
    context.font = `700 ${EVENT_TEXT_SIZE}px sans-serif`;
    context.fillStyle = TEXT;
    context.fillText(fit(context, row.body, right - CHAT_BODY_X - ageWidth), CHAT_BODY_X, baseline);
    return;
  }

  if (row.kind === "diff") {
    token("diff", LABEL);
    const additions = `+${row.additions}`;
    const deletions = `-${row.deletions}`;
    context.font = "700 10px monospace";
    // Painted as one right-aligned run so a long path cannot collide with the
    // counts, with each half keeping its own tint.
    const countsWidth = context.measureText(`${additions} ${deletions}`).width;
    context.fillStyle = DIFF_DEL;
    context.fillText(deletions, right - context.measureText(deletions).width, baseline);
    context.fillStyle = DIFF_ADD;
    context.fillText(additions, right - countsWidth, baseline);

    const budget = right - CHAT_BODY_X - countsWidth - 8;
    context.font = `600 ${EVENT_TEXT_SIZE - 1}px monospace`;
    context.fillStyle = MUTED;
    const pathWidth = context.measureText(`${row.path} `).width;
    context.fillText(fit(context, row.path, budget), CHAT_BODY_X, baseline);
    if (row.line !== null && pathWidth < budget) {
      context.fillStyle = row.line.startsWith("+") ? DIFF_ADD : row.line.startsWith("-") ? DIFF_DEL : LABEL;
      context.fillText(fit(context, row.line, budget - pathWidth), CHAT_BODY_X + pathWidth, baseline);
    }
    return;
  }

  token(row.role, directionBadgeColor(ROLE_BADGES[row.role] ?? "INFO"));
  context.font = `600 ${EVENT_TEXT_SIZE}px sans-serif`;
  context.fillStyle = MUTED;
  context.fillText(fit(context, row.body, right - CHAT_BODY_X), CHAT_BODY_X, baseline);
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
  const right = width - PAD;
  if (content.rows.length === 0) {
    context.font = `600 ${EVENT_TEXT_SIZE}px sans-serif`;
    context.fillStyle = LABEL;
    context.fillText("No chat yet.", CHAT_BODY_X, CHAT_FIRST_BASELINE + CHAT_LINE_HEIGHT);
  }
  content.rows.forEach((row, index) => {
    drawChatRow(context, row, right, CHAT_FIRST_BASELINE + index * CHAT_LINE_HEIGHT, now);
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

  const percent = `${Math.round(model.percent)}%`;
  context.font = "700 22px sans-serif";
  const percentWidth = rightText(context, percent, right, 30, TEXT);
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

  meter(context, left, 74, right - left, model.percent / 100, progressBarColor(model.percent), 10);
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
      return drawProviders(context, width, content.model, now);
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

/**
 * Touch-strip segment painting.
 *
 * The Plus strip is one 800x100 LCD the sidecar treats as four independently
 * repaintable 200x100 regions. This module paints one region from its
 * {@link SegmentContent} descriptor, following the mock's strip spec in
 * `docs/design/streamdeck/README.md`.
 *
 * The parity point that a single-number rendering gets wrong: a provider
 * segment carries **two** meters, session and weekly, each with its own bar and
 * reset caption. Collapsing them to one percentage — which is what the previous
 * `Claude: 0%` text did — loses the reading an operator actually needs, and
 * shows "0%" for a provider whose meter simply has not reported yet. `hasData`
 * distinguishes "no reading" from "zero usage", so the two must render
 * differently.
 */
import type { SKRSContext2D } from "@napi-rs/canvas";

import type { TranscriptRow } from "../channel.js";
import type { SegmentContent } from "../touchStrip/stripLayout.js";
import type { ProviderSegmentModel } from "../touchStrip/providerSegment.js";
import { BADGE_IDS, bucketContract, directionBadgeColor, progressBarColor, type DirectionBadge } from "../key-face-contract.js";
import { createPaint } from "./gradient.js";
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

const PAD = 12;
const METER_HEIGHT = 8;

/*
 * Shared vertical grid. All four segments are read as one strip, so the title,
 * the value row and the bar must land on the same baselines with the same
 * bottom margin — otherwise the bars visibly stagger across the strip.
 */
/** Title baseline: "SUMMARY", "Claude", "Codex", "MORE AGENTS". */
const TITLE_BASELINE = 30;
/** Font shared by every segment title. */
const TITLE_FONT = "700 18px sans-serif";
/** Baseline for the label/value row above the bar. */
const VALUE_BASELINE = 68;
/** Top of the bar; 100 - BAR_TOP - METER_HEIGHT is the bottom margin. */
const BAR_TOP = 76;
/** Width of every bar. */
const BAR_WIDTH = 200 - PAD * 2;

/** Small uppercase caption used for segment headings. */
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
): void => {
  const clamped = Math.max(0, Math.min(1, fraction));
  context.beginPath();
  context.roundRect(x, y, width, METER_HEIGHT, METER_HEIGHT / 2);
  context.fillStyle = TRACK;
  context.fill();
  const filled = Math.round(width * clamped);
  if (filled > 0) {
    context.beginPath();
    context.roundRect(x, y, Math.max(filled, METER_HEIGHT), METER_HEIGHT, METER_HEIGHT / 2);
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

/** Segment 1 in grid mode: live/left counts plus the build mini-bar. */
const drawSummary = (context: SKRSContext2D, model: SegmentContent & { kind: "summary" }): void => {
  const mark = 20;
  drawBrandMark(context, PAD, TITLE_BASELINE - mark + 4, mark);
  context.font = TITLE_FONT;
  context.fillStyle = TEXT;
  const titleEnd = PAD + mark + 7 + context.measureText("Summary").width;
  context.fillText("Summary", PAD + mark + 7, TITLE_BASELINE);

  // Live count only, with its dot. The fleet total belongs to the pager
  // segment, which is where an operator looks to page through it.
  void titleEnd;
  const live = `${model.model.live}`;
  context.font = "700 18px sans-serif";
  const liveWidth = context.measureText(live).width;
  context.fillStyle = TEXT;
  context.fillText(live, 200 - PAD - liveWidth, TITLE_BASELINE);
  context.beginPath();
  context.arc(200 - PAD - liveWidth - 11, TITLE_BASELINE - 6, 4.5, 0, Math.PI * 2);
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
    const eta = `ETA ${build.etaLabel}`;
    context.fillStyle = LABEL;
    context.fillText(eta, 200 - PAD - context.measureText(eta).width, VALUE_BASELINE);
  }
  meter(context, PAD, BAR_TOP, BAR_WIDTH, build.fraction, miniBarFill(context, PAD, BAR_WIDTH));
};

/**
 * Segments 2-3 in grid mode: one provider's session meter.
 *
 * The mock stacks a session and a weekly meter here. At 200x100 on a device
 * read from arm's length that made six lines of sub-11px type, so by operator
 * decision this shows the session window only, at roughly double the type size.
 * Weekly is still projected and available if it earns its space back.
 */
const drawProvider = (
  context: SKRSContext2D,
  label: string,
  model: ProviderSegmentModel,
  now: number,
): void => {
  const mark = 22;
  drawVendorMark(context, label, PAD, TITLE_BASELINE - mark + 4, mark);
  context.font = TITLE_FONT;
  context.fillStyle = TEXT;
  context.fillText(label.charAt(0).toUpperCase() + label.slice(1), PAD + mark + 8, TITLE_BASELINE);

  if (!model.hasData) {
    context.font = "700 13px sans-serif";
    context.fillStyle = LABEL;
    context.fillText("Awaiting data", PAD, VALUE_BASELINE);
    return;
  }

  const window = model.session;
  if (window === null) {
    context.font = "700 13px sans-serif";
    context.fillStyle = LABEL;
    context.fillText("No session window", PAD, VALUE_BASELINE);
    return;
  }

  const percent = Math.round(window.usedPercent);
  const reset = resetLabel(window.resetsAt, now);

  context.font = "700 13px sans-serif";
  context.fillStyle = LABEL;
  context.fillText("Session", PAD, VALUE_BASELINE);

  const right = reset === null ? `${percent}%` : `${percent}% · ${reset}`;
  context.fillStyle = MUTED;
  context.fillText(right, 200 - PAD - context.measureText(right).width, VALUE_BASELINE);

  meter(context, PAD, BAR_TOP, BAR_WIDTH, percent / 100, miniBarFill(context, PAD, BAR_WIDTH));
};

/**
 * Segment 4 in grid mode: the window pager.
 *
 * The agent count lives on the summary segment, so it is not repeated here.
 * The title carries the same weight as the other three so the strip reads as
 * one row, and the dots sit on the shared bar line.
 */
const drawPager = (context: SKRSContext2D, content: SegmentContent & { kind: "pager" }): void => {
  const centre = (text: string): number => (200 - context.measureText(text).width) / 2;

  // The fleet total is the heading. "MORE AGENTS" over "32 Agents" said the
  // same thing twice, and the count is the part an operator reads when deciding
  // whether to page.
  context.font = TITLE_FONT;
  context.fillStyle = TEXT;
  context.fillText(content.label, centre(content.label), TITLE_BASELINE);

  const dots = content.model.dots;
  const spacing = 16;
  const startX = (200 - (dots.length - 1) * spacing) / 2;
  dots.forEach((filled, index) => {
    context.beginPath();
    context.arc(startX + index * spacing, BAR_TOP + METER_HEIGHT / 2, 4.5, 0, Math.PI * 2);
    context.fillStyle = filled ? DOT_ON : DOT_OFF;
    context.fill();
  });
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
 * strip's segments are cached by their rendered bytes: a clipped glyph still
 * changes the JPEG, so two rows that read the same would repaint each other.
 */
const fit = (context: SKRSContext2D, text: string, maxWidth: number): string => {
  // A caller can hand this a negative budget when a long right-aligned run eats
  // the region; nothing fits, so draw nothing rather than the bare ellipsis.
  if (maxWidth <= 0) return "";
  if (context.measureText(text).width <= maxWidth) return text;
  let clipped = text;
  while (clipped.length > 1 && context.measureText(`${clipped}…`).width > maxWidth) clipped = clipped.slice(0, -1);
  return `${clipped}…`;
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

/** One transcript row in a 200x100 region: header, diff, or message. */
const drawChat = (context: SKRSContext2D, row: TranscriptRow, now: number): void => {
  const width = 200 - PAD * 2;
  if (row.kind === "event_header") {
    const age = ageLabel(row.timestamp, now);
    context.font = "700 10px monospace";
    const ageWidth = age === null ? 0 : context.measureText(age).width + 8;
    // The badge is whatever string the feed sent, so it is clipped to the space
    // the age is not using; an over-long badge otherwise overprints the age.
    caption(context, fit(context, row.badge.toUpperCase(), width - ageWidth), PAD, 30, badgeColour(row.badge));
    if (age !== null) {
      context.font = "700 10px monospace";
      context.fillStyle = LABEL;
      context.fillText(age, 200 - PAD - context.measureText(age).width, 30);
    }
    context.font = "700 12px sans-serif";
    context.fillStyle = TEXT;
    context.fillText(fit(context, row.body, width), PAD, 56);
    return;
  }
  if (row.kind === "diff") {
    const counts = `+${row.additions} -${row.deletions}`;
    context.font = "700 10px monospace";
    const countsWidth = context.measureText(counts).width;
    context.fillStyle = LABEL;
    context.fillText(fit(context, row.path, width - countsWidth - 8), PAD, 30);
    // The two counts are painted as one right-aligned run so they cannot
    // collide with a long path, and each keeps its own tint.
    const additions = `+${row.additions}`;
    context.fillStyle = DIFF_ADD;
    context.fillText(additions, 200 - PAD - countsWidth, 30);
    context.fillStyle = DIFF_DEL;
    context.fillText(`-${row.deletions}`, 200 - PAD - countsWidth + context.measureText(`${additions} `).width, 30);
    if (row.line !== null) {
      context.font = "600 11px monospace";
      context.fillStyle = row.line.startsWith("+") ? DIFF_ADD : row.line.startsWith("-") ? DIFF_DEL : MUTED;
      context.fillText(fit(context, row.line, width), PAD, 56);
    }
    return;
  }
  caption(context, row.role, PAD, 30, directionBadgeColor(ROLE_BADGES[row.role] ?? "INFO"));
  context.font = "600 12px sans-serif";
  context.fillStyle = MUTED;
  context.fillText(fit(context, row.body, width), PAD, 56);
};

/** Renders one segment's content onto a 200x100 context. */
export const drawSegmentContent = (
  context: SKRSContext2D,
  content: SegmentContent,
  now: number = Date.now(),
): void => {
  context.fillStyle = BG;
  context.fillRect(0, 0, 200, 100);
  context.strokeStyle = DIVIDER;
  context.lineWidth = 1;
  context.beginPath();
  context.moveTo(199.5, 8);
  context.lineTo(199.5, 92);
  context.stroke();

  switch (content.kind) {
    case "summary":
      drawSummary(context, content);
      return;
    case "provider":
      drawProvider(context, content.label, content.model, now);
      return;
    case "pager":
      drawPager(context, content);
      return;
    case "controlling":
      caption(context, "controlling", PAD, 30);
      context.font = "700 26px monospace";
      context.fillStyle = TEXT;
      context.fillText(content.ticketId, PAD, 66);
      return;
    case "agentIdentity":
      caption(context, "agent", PAD, 30);
      context.font = "700 15px sans-serif";
      context.fillStyle = TEXT;
      context.fillText(content.identity, PAD, 58);
      return;
    case "agentProgress": {
      caption(context, content.status, PAD, 30);
      const percent = Math.round(content.percent);
      context.font = "700 20px sans-serif";
      context.fillStyle = TEXT;
      context.fillText(`${percent}%`, PAD, 60);
      meter(context, PAD, 72, 200 - PAD * 2, percent / 100, progressBarColor(percent));
      return;
    }
    case "chat":
      // A null row is a slot past the end of the transcript: it paints the
      // background only, rather than an empty label the operator has to read.
      if (content.row !== null) drawChat(context, content.row, now);
      return;
    case "hint": {
      const arrow = content.direction === "back" ? "←" : "→";
      context.font = "700 13px sans-serif";
      context.fillStyle = ACCENT_LIVE;
      const text = content.direction === "back" ? `${arrow} ${content.label}` : `${content.label} ${arrow}`;
      context.fillText(text.toUpperCase(), (200 - context.measureText(text.toUpperCase()).width) / 2, 56);
      return;
    }
  }
};

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

import type { SegmentContent } from "../touchStrip/stripLayout.js";
import { encoderCenterX } from "../touchStrip/geometry.js";
import { PROVIDER_SCROLL_ENCODER, VISIBLE_PROVIDER_ROWS, type ProviderPanelRow } from "../touchStrip/providerPanel.js";
import { drawAccountSummary, accountReadingText } from "./providerAccountSummary.js";
import { fit, resetLabel, rightText } from "./segmentText.js";
import { drawBrandMark, drawVendorMark } from "./vendorMark.js";
import {
  BG,
  DIVIDER,
  LABEL,
  TEXT,
  MUTED,
  ACCENT_LIVE,
  DOT_ON,
  DOT_OFF,
  PAD,
  METER_HEIGHT,
  HEIGHT,
  TITLE_BASELINE,
  TITLE_FONT,
  VALUE_BASELINE,
  BAR_TOP,
  miniBarFill,
  meter,
} from "./segmentStyle.js";

import { drawChatLog } from "./chat-readout.js";
import { drawAgentDetail, drawCommandsPanel, drawSettingsPanel, drawVoicePanel } from "./segmentPanels.js";

export { COMMANDS_ERROR, OPEN_AMBER } from "./segmentPanels.js";
export { ageLabel, resetLabel } from "./segmentText.js";

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
  drawAccountSummary(context, row.summaryLabel, PAD, TITLE_BASELINE + 17, width - PAD * 2);

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
    const readingWidth = rightText(context, accountReadingText(reading.text, row.summaryLabel), right, baseline, reading.fraction === null ? LABEL : MUTED);
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
    case "voice":
      return drawVoicePanel(context, width, content);
    case "settings":
      return drawSettingsPanel(context, width, content);
    case "commands":
      return drawCommandsPanel(context, width, content);
    case "blank":
      // A panel with no provider configured for it. Bare background only: an
      // "Awaiting data" label here would claim a provider exists.
      return;
  }
};

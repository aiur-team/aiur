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

import type { SegmentContent } from "../touchStrip/stripLayout.js";
import type { ProviderSegmentModel } from "../touchStrip/providerSegment.js";
import { progressBarColor } from "../key-face-contract.js";
import { drawVendorMark } from "./vendorMark.js";

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
const METER_HEIGHT = 5;

/** Small uppercase caption used for segment headings. */
const caption = (context: SKRSContext2D, text: string, x: number, y: number, color = LABEL): void => {
  context.font = "700 10px monospace";
  context.fillStyle = color;
  context.fillText(text.toUpperCase(), x, y);
};

/** A rounded meter with a filled portion; `fraction` is clamped to 0..1. */
const meter = (
  context: SKRSContext2D,
  x: number,
  y: number,
  width: number,
  fraction: number,
  color: string,
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
  caption(context, "summary", PAD, 22);

  context.font = "700 22px sans-serif";
  context.fillStyle = TEXT;
  context.fillText(`${model.model.live}`, PAD, 50);
  const liveWidth = context.measureText(`${model.model.live}`).width;
  context.font = "600 12px sans-serif";
  context.fillStyle = MUTED;
  context.fillText(`live · ${model.model.remaining} left`, PAD + liveWidth + 6, 50);

  const build = model.model.build;
  if (build === null) {
    context.font = "600 11px sans-serif";
    context.fillStyle = LABEL;
    context.fillText("No build order", PAD, 76);
    return;
  }
  context.font = "600 11px sans-serif";
  context.fillStyle = MUTED;
  const percent = Math.round(build.fraction * 100);
  context.fillText(`Build ${percent}%`, PAD, 72);
  if (build.etaLabel !== null) {
    const eta = `ETA ${build.etaLabel}`;
    context.fillStyle = LABEL;
    context.fillText(eta, 200 - PAD - context.measureText(eta).width, 72);
  }
  meter(context, PAD, 80, 200 - PAD * 2, build.fraction, progressBarColor(percent));
};

/** Segments 2-3 in grid mode: one provider, session and weekly meters. */
const drawProvider = (
  context: SKRSContext2D,
  label: string,
  model: ProviderSegmentModel,
  now: number,
): void => {
  drawVendorMark(context, label, PAD, 12, 14);
  context.font = "700 12px sans-serif";
  context.fillStyle = TEXT;
  context.fillText(label.charAt(0).toUpperCase() + label.slice(1), PAD + 20, 23);

  if (!model.hasData) {
    context.font = "600 11px sans-serif";
    context.fillStyle = LABEL;
    context.fillText("Awaiting data", PAD, 52);
    return;
  }

  const rows: readonly [string, typeof model.session][] = [
    ["Session", model.session],
    ["Weekly", model.weekly],
  ];
  rows.forEach(([name, window], index) => {
    const top = 38 + index * 30;
    context.font = "600 10px sans-serif";
    context.fillStyle = LABEL;
    context.fillText(name, PAD, top);

    if (window === null) {
      context.fillStyle = LABEL;
      context.fillText("—", 200 - PAD - 8, top);
      return;
    }

    const percent = Math.round(window.usedPercent);
    const reset = resetLabel(window.resetsAt, now);
    const right = reset === null ? `${percent}%` : `${percent}% · ${reset}`;
    context.font = "700 10px sans-serif";
    context.fillStyle = MUTED;
    context.fillText(right, 200 - PAD - context.measureText(right).width, top);

    meter(context, PAD, top + 5, 200 - PAD * 2, percent / 100, progressBarColor(percent));
  });
};

/** Segment 4 in grid mode: window pager dots. */
const drawPager = (context: SKRSContext2D, content: SegmentContent & { kind: "pager" }): void => {
  context.font = "700 11px monospace";
  context.fillStyle = TEXT;
  const title = content.title.toUpperCase();
  context.fillText(title, (200 - context.measureText(title).width) / 2, 40);

  context.font = "600 10px sans-serif";
  context.fillStyle = LABEL;
  context.fillText(content.label, (200 - context.measureText(content.label).width) / 2, 58);

  const dots = content.model.dots;
  const spacing = 14;
  const startX = (200 - (dots.length - 1) * spacing) / 2;
  dots.forEach((filled, index) => {
    context.beginPath();
    context.arc(startX + index * spacing, 74, 3.5, 0, Math.PI * 2);
    context.fillStyle = filled ? DOT_ON : DOT_OFF;
    context.fill();
  });
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
      context.font = "600 12px sans-serif";
      context.fillStyle = MUTED;
      context.fillText(content.line, PAD, 56);
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

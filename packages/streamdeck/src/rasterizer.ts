import { createCanvas, type Canvas, type CanvasRenderingContext2D } from "@napi-rs/canvas";
import { composeKeyFace, type AgentKeyFace, type KeyFace } from "./keys/keyFace.js";
import { progressBarColor } from "./keys.js";
import type { KeyDescriptor } from "./keys.js";
import type { SegmentContent } from "./touchStrip/stripLayout.js";

export interface RasterizerOptions {
  readonly jpegQuality?: number;
}

const quality = (value: number | undefined): number => Math.max(1, Math.min(100, Math.trunc(value ?? 90)));

const drawText = (context: CanvasRenderingContext2D, text: string, x: number, y: number, size: number, colour = "#ffffff"): void => {
  context.fillStyle = colour;
  context.font = `${size}px sans-serif`;
  context.fillText(text, x, y);
};

const hex = (colour: string): string => colour.startsWith("#") ? colour : `#${colour}`;

/** Progress-bar geometry on a 120px key, mirroring the emulator's footer row. */
const FOOTER_TOP = 101;
const BAR_HEIGHT = 6;
const DOT_SIZE = 9;
/** Light grey track: clearly a container, never a second value segment. */
const BAR_TRACK = "rgba(255,255,255,0.14)";

/**
 * Draws the key-face progress footer: a status dot plus one-colour bar.
 *
 * The bar is a single green at every measured value, a brighter green at 100%,
 * with no border. Unknown reads as a hollow dot + dashed track — structurally
 * different from a real 0%, which paints a solid stub, so the deck never
 * claims "everything is at zero" when it means "could not measure".
 */
const drawProgressFooter = (context: CanvasRenderingContext2D, face: AgentKeyFace): void => {
  if (face.footer.kind !== "progress") return;
  const footer = face.footer;
  const unknown = footer.percent === null;
  context.beginPath();
  context.arc(13, FOOTER_TOP + DOT_SIZE / 2, DOT_SIZE / 2 - (unknown ? 0.75 : 0), 0, Math.PI * 2);
  if (unknown) {
    context.strokeStyle = hex(face.accent);
    context.lineWidth = 1.5;
    context.stroke();
  } else {
    context.fillStyle = hex(face.accent);
    context.fill();
  }

  const barX = 22;
  const barWidth = 120 - 8 - barX;
  const barY = FOOTER_TOP + (DOT_SIZE - BAR_HEIGHT) / 2;
  context.fillStyle = BAR_TRACK;
  context.fillRect(barX, barY, barWidth, BAR_HEIGHT);

  if (unknown) {
    // A dashed track and no fill at all. This is the state that used to be
    // indistinguishable from a real 0%: both painted an empty bar, so a ticket
    // whose reading had gone missing looked like a ticket that had done
    // nothing. Dashes say "no reading", a solid stub says "zero".
    context.strokeStyle = footer.barColor;
    context.lineWidth = BAR_HEIGHT;
    context.setLineDash([4, 5]);
    context.beginPath();
    context.moveTo(barX + 2, barY + BAR_HEIGHT / 2);
    context.lineTo(barX + barWidth - 2, barY + BAR_HEIGHT / 2);
    context.stroke();
    context.setLineDash([]);
    context.lineWidth = 1;
    drawText(context, "—", 88, 109, 10);
    return;
  }

  // `Math.max(..., BAR_HEIGHT)` applies at 0 as well: a known 0% paints a
  // visible stub rather than an empty bar, keeping "just started" apart from
  // "no reading".
  const filled = Math.max(Math.round((barWidth * footer.percent) / 100), BAR_HEIGHT);
  context.fillStyle = hex(footer.barColor);
  context.fillRect(barX, barY, filled, BAR_HEIGHT);
  drawText(context, `${footer.percent}%`, 88, 109, 10);
};

const drawKey = (canvas: Canvas, face: KeyFace): void => {
  const context = canvas.getContext("2d");
  if (face.kind === "empty") {
    context.fillStyle = "#000000";
    context.fillRect(0, 0, 120, 120);
    return;
  }
  context.fillStyle = hex(face.face);
  context.fillRect(0, 0, 120, 120);
  context.strokeStyle = hex(face.accent);
  context.lineWidth = 4;
  context.strokeRect(3, 3, 114, 114);
  drawText(context, face.vendor.toUpperCase(), 8, 18, 9, hex(face.accent));
  drawText(context, `#${face.ticketNumber}`, 8, 42, 18);
  drawText(context, face.titleLines[0], 8, 67, 12);
  drawText(context, face.titleLines[1], 8, 82, 12);
  if (face.footer.kind === "progress") {
    drawProgressFooter(context, face);
  } else {
    drawText(context, face.footer.statusLabel, 8, 110, 10, face.footer.unblocked ? "#7dffbd" : "#ffbf69");
  }
};

const segmentLabel = (content: SegmentContent): string => {
  switch (content.kind) {
    case "summary": return `${content.model.live} LIVE / ${content.model.remaining} LEFT`;
    case "provider": return `${content.label}: ${content.model.hasData ? `${content.model.session?.usedPercent ?? 0}%` : "NO DATA"}`;
    case "pager": return `${content.title} ${content.label}`;
    case "controlling": return `CONTROLLING #${content.ticketId}`;
    case "agentIdentity": return content.identity;
    case "agentProgress": return `${content.status} ${content.percent === null ? "—" : `${content.percent}%`}`;
    case "chat": return content.line;
    case "hint": return `${content.label} ${content.direction === "back" ? "←" : "→"}`;
  }
};

/** Touch-strip agent-progress panel: status text above a real one-colour bar. */
const drawAgentProgress = (context: CanvasRenderingContext2D, content: Extract<SegmentContent, { kind: "agentProgress" }>): void => {
  context.font = "700 13px sans-serif";
  context.fillStyle = "#f2f5ff";
  context.fillText(content.status.toUpperCase(), 8, 34);

  const barX = 8;
  const barY = 52;
  const barHeight = 10;
  const barWidth = 200 - barX * 2;
  context.fillStyle = BAR_TRACK;
  context.fillRect(barX, barY, barWidth, barHeight);

  if (content.percent === null) {
    // Same dashed no-reading track the key face uses.
    context.strokeStyle = "rgba(255,255,255,0.22)";
    context.lineWidth = barHeight;
    context.setLineDash([5, 6]);
    context.beginPath();
    context.moveTo(barX + 3, barY + barHeight / 2);
    context.lineTo(barX + barWidth - 3, barY + barHeight / 2);
    context.stroke();
    context.setLineDash([]);
    context.lineWidth = 1;
    context.fillStyle = "rgba(240,242,246,0.72)";
    context.fillText("—", 8, 86);
    return;
  }

  const filled = Math.max(Math.round((barWidth * content.percent) / 100), barHeight);
  context.fillStyle = progressBarColor(content.percent);
  context.fillRect(barX, barY, filled, barHeight);
  context.fillStyle = "#f2f5ff";
  context.fillText(`${content.percent}%`, 8, 86);
};

const drawSegment = (canvas: Canvas, content: SegmentContent): void => {
  const context = canvas.getContext("2d");
  context.fillStyle = "#11151f";
  context.fillRect(0, 0, 200, 100);
  context.strokeStyle = "#4e678f";
  context.strokeRect(1, 1, 198, 98);
  if (content.kind === "agentProgress") {
    drawAgentProgress(context, content);
    return;
  }
  drawText(context, segmentLabel(content), 8, 48, 14, "#f2f5ff");
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
      const canvas = createCanvas(120, 120);
      drawKey(canvas, composeKeyFace(descriptor));
      const encoded = encode(canvas);
      cache.set(cacheKey, encoded);
      return encoded.slice();
    },
    segment: (content: SegmentContent): Uint8Array => {
      const cacheKey = `segment:${JSON.stringify(content)}`;
      const cached = cache.get(cacheKey);
      if (cached !== undefined) return cached.slice();
      const canvas = createCanvas(200, 100);
      drawSegment(canvas, content);
      const encoded = encode(canvas);
      cache.set(cacheKey, encoded);
      return encoded.slice();
    },
  };
};

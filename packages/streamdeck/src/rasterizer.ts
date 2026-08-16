import { createCanvas, type Canvas, type CanvasRenderingContext2D } from "@napi-rs/canvas";
import { composeKeyFace, type KeyFace } from "./keys/keyFace.js";
import type { KeyDescriptor } from "./keys.js";
import type { ChatKind } from "./touchStrip/stripLayout.js";
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

// The three row classes plus the rare user turn, matching the emulator's
// opencode-borrowed palette so the physical deck and the emulator agree.
const CHAT_COLOURS: Readonly<Record<ChatKind, string>> = {
  command: "#88e0a6",
  agent: "#9fd0ff",
  logs: "#ffcf87",
  user: "#c69bff",
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
    context.fillStyle = hex(face.footer.barColor);
    context.fillRect(8, 101, Math.round(face.footer.percent), 8);
    drawText(context, `${face.footer.percent}%`, 88, 109, 10);
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
    case "agentProgress": return `${content.status} ${content.percent}%`;
    case "chat": return content.glyph ? `${content.glyph} ${content.line}` : content.line;
    case "hint": return `${content.label} ${content.direction === "back" ? "←" : "→"}`;
  }
};

const drawSegment = (canvas: Canvas, content: SegmentContent): void => {
  const context = canvas.getContext("2d");
  context.fillStyle = "#11151f";
  context.fillRect(0, 0, 200, 100);
  context.strokeStyle = "#4e678f";
  context.strokeRect(1, 1, 198, 98);
  const colour = content.kind === "chat" ? CHAT_COLOURS[content.chatKind] : "#f2f5ff";
  drawText(context, segmentLabel(content), 8, 48, 14, colour);
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

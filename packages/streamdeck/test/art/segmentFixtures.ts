import { PROVIDER_SCROLL_BAND_TOP } from "../../src/art/segments.js";
import type { TranscriptRow } from "../../src/channel.js";
import type { SegmentContent } from "../../src/touchStrip/stripLayout.js";
import type { ProviderSegmentModel } from "../../src/touchStrip/providerSegment.js";
import { type ProviderPanelRow } from "../../src/touchStrip/providerPanel.js";
import type { SummaryModel } from "../../src/touchStrip/summarySegment.js";
import { BACKGROUND, render, type Ink, type Render } from "./renderSegment.js";

export const EMIT = "#9fd0ff";
export const INFO = "#c2c6cf";
export const LABEL = "rgba(255,255,255,0.55)";
export const ACCENT_LIVE = "#4ade80";

/*
 * The transcript palette, quoted from opencode's default theme exactly as
 * `segments.ts` quotes it. Written out again here rather than imported so a
 * silent edit to the borrowed palette has to be made twice, deliberately.
 */
export const TEXT_BRIGHT = "#eeeeee";
export const TEXT_MUTED = "#808080";
export const PANEL = [0x14, 0x14, 0x14] as const;
export const USER_BAR = [0x5c, 0x9c, 0xf5] as const;
export const DIFF_ADDED_BG = [0x20, 0x30, 0x3b] as const;
export const DIFF_REMOVED_BG = [0x37, 0x22, 0x2c] as const;
export const ADDED_SIGN = "#b8db87";
export const REMOVED_SIGN = "#e26a75";

/**
 * The #1960 row-class colours, quoted from the emulator's opencode-borrowed
 * logs palette (#1934) exactly as `segments.ts` quotes them. Written out again
 * here rather than imported so a silent edit to the palette has to be made
 * twice, deliberately.
 */
export const COMMAND_COLOUR = "#88e0a6";
export const AGENT_COLOUR = "#9fd0ff";
export const LOGS_COLOUR = "#ffcf87";
export const USER_COLOUR = "#c69bff";

/** Columns carrying something other than background in `top`..`bottom`. */
export const inkedColumns = (pixels: Uint8ClampedArray, width: number, top: number, bottom: number): number[] => {
  // `render` trims the divider column, so a row is one pixel narrower.
  const stride = width - 1;
  const columns: number[] = [];
  for (let x = 0; x < stride; x += 1) {
    for (let y = top; y < bottom; y += 1) {
      const i = (y * stride + x) * 4;
      if (pixels[i] !== BACKGROUND[0] || pixels[i + 1] !== BACKGROUND[1] || pixels[i + 2] !== BACKGROUND[2]) {
        columns.push(x);
        break;
      }
    }
  }
  return columns;
};

/** Columns in the scroll band painted in the lit colour, i.e. a live chevron. */
export const litColumns = (pixels: Uint8ClampedArray, width: number): number[] => {
  const stride = width - 1;
  const columns: number[] = [];
  for (let x = 0; x < stride; x += 1) {
    for (let y = PROVIDER_SCROLL_BAND_TOP; y < 100; y += 1) {
      const i = (y * stride + x) * 4;
      if (pixels[i] === 0xf1 && pixels[i + 1] === 0xf3 && pixels[i + 2] === 0xf6) {
        columns.push(x);
        break;
      }
    }
  }
  return columns;
};

/** One transcript row, painted as the sole line of an 800-wide chat readout. */
export const chat = (row: TranscriptRow, width = 800): Ink[] => render(chatLog([row]), width).ink;

/** The same, keeping the pixels: the fills and bars carry the speaker. */
export const chatPixels = (row: TranscriptRow, width = 800): Render => render(chatLog([row]), width);

/** The colour at a panel coordinate. `render` trims the divider column. */
export const pixelAt = (pixels: Uint8ClampedArray, width: number, x: number, y: number): number[] => {
  const index = (y * (width - 1) + x) * 4;
  return [pixels[index], pixels[index + 1], pixels[index + 2]];
};

/** Mid-height of the transcript row at `index`, for sampling its fill. */
export const rowMiddle = (index: number): number => 10 + index * 16;

export type HeaderRow = Extract<TranscriptRow, { kind: "event_header" }>;
export type DiffRow = Extract<TranscriptRow, { kind: "diff" }>;
export type MessageRow = Extract<TranscriptRow, { kind: "message" }>;

export const header = (over: Partial<HeaderRow> = {}): HeaderRow => ({
  kind: "event_header",
  badge: "EMIT",
  label: "PR merged",
  body: "PR merged",
  timestamp: null,
  ...over,
});

export const diffRow = (over: Partial<DiffRow> = {}): DiffRow => ({
  kind: "diff",
  path: "lib/a.ex",
  additions: 0,
  deletions: 0,
  line: null,
  ...over,
});

export type DiffLineRow = Extract<TranscriptRow, { kind: "diff_line" }>;

export const diffLineRow = (over: Partial<DiffLineRow> = {}): DiffLineRow => ({
  kind: "diff_line",
  sign: " ",
  text: "  unchanged",
  ...over,
});

export const message = (over: Partial<MessageRow> = {}): MessageRow => ({
  kind: "message",
  role: "assistant",
  body: "",
  tool: null,
  ...over,
});

export const chatLog = (
  rows: readonly TranscriptRow[],
  bounds: Partial<Pick<SegmentContent & { kind: "chatLog" }, "chatHasPrevious" | "chatHasNext" | "eventHasPrevious" | "eventHasNext">> = {},
): SegmentContent => ({
  kind: "chatLog",
  rows,
  chatHasPrevious: false,
  chatHasNext: false,
  eventHasPrevious: false,
  eventHasNext: false,
  ...bounds,
});

export const drew = (ink: Ink[], text: string): Ink | undefined => ink.find((entry) => entry.text === text);

export const summary = (build: SummaryModel["build"]): SegmentContent => ({
  kind: "summary",
  model: { live: 7, remaining: 25, build },
});

export const providerRow = (label: string, model: Partial<ProviderSegmentModel>): ProviderPanelRow => ({
  label,
  model: { provider: label, session: null, weekly: null, freshness: "fresh", hasData: true, ...model },
});

export const provider = (model: Partial<ProviderSegmentModel>): SegmentContent => ({
  kind: "provider",
  row: providerRow("claude", model),
});

export const session = (usedPercent: number, resetsAt: string | null = null): Partial<ProviderSegmentModel> => ({
  session: { usedPercent, resetsAt },
});

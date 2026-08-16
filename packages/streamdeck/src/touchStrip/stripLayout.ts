/**
 * Touch-strip mode layouts — which content each of the four segments carries in
 * each mode.
 *
 * The strip has three modes. This module maps a mode + real data into a fixed
 * four-entry array of `SegmentContent`, one per project-owned region (see
 * `geometry.ts`). It is the single place the "what goes where" decision lives,
 * kept apart from `StripRenderer`, which only encodes and diffs.
 *
 * Segment role assignments below are a PROJECT DECISION, not a hardware spec —
 * the device defines no per-segment meaning. They are chosen to keep each
 * region independently repaintable (a provider tick or a chat line touches one
 * region), which is the whole reason the strip is modelled as four regions.
 *
 * Modes (from the ticket spec):
 *
 *   - `grid`: [Summary, Claude usage, Codex usage, Pager]
 *   - `cmd`:  [agent identity, status+percent+bar, BACK hint, "CONTROLLING" +
 *             active ticket] — the pager region becomes the controlling label.
 *   - `logs`: [BACK hint, chat line 1, chat line 2, EVENTS hint] — the two-line
 *             chat window (#1351) flanked by the two hint arrows.
 *
 * Content is a structured descriptor, not pixels: the encoder (device/render
 * path in #1354/#1355, or OpenDeck's layout system per #1342) turns each
 * descriptor into a segment JPEG. Keeping it structured makes both the layout
 * choices and the per-segment diffing testable without a canvas.
 */
import type { PagerModel } from "./pagerSegment.js";
import type { ProviderSegmentModel } from "./providerSegment.js";
import type { SummaryModel } from "./summarySegment.js";

/** The three touch-strip modes. */
export type StripMode = "grid" | "cmd" | "logs";

/** A directional hint arrow drawn in a segment. */
export interface HintContent {
  readonly kind: "hint";
  /** Short caption such as "BACK" or "EVENTS". */
  readonly label: string;
  readonly direction: "back" | "forward";
}

/**
 * The three visually-distinct row classes plus the rare user turn. Commands
 * and tool rows share the command colour; agent prose is its own class; system
 * context rows (event headers, diffs, logs) are the third. Mirrors the server's
 * `StreamdeckLogs.row_kind/1` so the physical deck matches the emulator.
 */
export type ChatKind = "command" | "agent" | "logs" | "user";

/** One transcript row for the device strip, carrying its colour class. */
export interface ChatLine {
  readonly text: string;
  readonly kind: ChatKind;
  /** opencode-style gutter glyph (`$`, `→`, `←`, `⚙`); absent for prose. */
  readonly glyph?: string;
}

/** Structured content for one segment; the encoder renders it to a JPEG. */
export type SegmentContent =
  | { readonly kind: "summary"; readonly model: SummaryModel }
  | { readonly kind: "provider"; readonly label: string; readonly model: ProviderSegmentModel }
  | { readonly kind: "pager"; readonly title: string; readonly label: string; readonly model: PagerModel }
  | { readonly kind: "controlling"; readonly ticketId: string }
  | { readonly kind: "agentIdentity"; readonly identity: string }
  | {
      readonly kind: "agentProgress";
      readonly status: string;
      /** Progress percent, 0..100. */
      readonly percent: number;
    }
  | { readonly kind: "chat"; readonly line: string; readonly chatKind: ChatKind; readonly glyph?: string }
  | HintContent;

/** Data the `grid` mode needs. Every field is a real projection, not invented. */
export interface GridData {
  readonly summary: SummaryModel;
  readonly claude: ProviderSegmentModel;
  readonly codex: ProviderSegmentModel;
  readonly pager: PagerModel;
  /** Caption under the pager dots, e.g. a window range. */
  readonly pagerLabel: string;
}

/** Data the `cmd` mode needs: the controlled agent and its ticket. */
export interface CmdData {
  readonly identity: string;
  readonly status: string;
  /** Progress percent, 0..100. */
  readonly percent: number;
  readonly ticketId: string;
}

/** Data the `logs` mode needs: the two-line chat window (#1351). */
export interface LogsData {
  /** Chat lines, newest last; only the first two are shown. */
  readonly lines: readonly ChatLine[];
  readonly chatHasPrevious?: boolean;
  readonly chatHasNext?: boolean;
  readonly eventHasPrevious?: boolean;
  readonly eventHasNext?: boolean;
}

/** Discriminated per-mode data union passed to {@link composeStrip}. */
export type StripData =
  | { readonly mode: "grid"; readonly data: GridData }
  | { readonly mode: "cmd"; readonly data: CmdData }
  | { readonly mode: "logs"; readonly data: LogsData };

const BACK_HINT: HintContent = { kind: "hint", label: "BACK", direction: "back" };
const hint = (label: string, direction: "back" | "forward"): HintContent => ({ kind: "hint", label, direction });

function clampPercent(value: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  if (value < 0) return 0;
  if (value > 100) return 100;
  return value;
}

function chatLine(lines: readonly ChatLine[], index: number): SegmentContent {
  const line = lines[index];
  if (line === undefined) return { kind: "chat", line: "", chatKind: "logs" };
  return { kind: "chat", line: line.text, chatKind: line.kind, glyph: line.glyph };
}

/**
 * Compose the four segment contents for a mode. Always returns exactly
 * {@link SEGMENT_COUNT} entries, left to right, so every mode drives all four
 * regions and the renderer can diff them uniformly. Each `case` yields a
 * literal four-element array, so the count is guaranteed by construction and
 * the exhaustive `switch` is checked by the compiler.
 */
export function composeStrip(input: StripData): readonly [
  SegmentContent,
  SegmentContent,
  SegmentContent,
  SegmentContent,
] {
  switch (input.mode) {
    case "grid": {
      const { summary, claude, codex, pager, pagerLabel } = input.data;
      return [
        { kind: "summary", model: summary },
        { kind: "provider", label: "Claude", model: claude },
        { kind: "provider", label: "Codex", model: codex },
        { kind: "pager", title: "MORE AGENTS", label: pagerLabel, model: pager },
      ];
    }
    case "cmd": {
      const { identity, status, percent, ticketId } = input.data;
      return [
        { kind: "agentIdentity", identity },
        { kind: "agentProgress", status, percent: clampPercent(percent) },
        BACK_HINT,
        { kind: "controlling", ticketId },
      ];
    }
    case "logs": {
      const { lines } = input.data;
      const chatLabel = input.data.chatHasPrevious || input.data.chatHasNext ? "CHAT" : "BACK";
      const eventLabel = input.data.eventHasPrevious && input.data.eventHasNext ? "EVENTS ↑↓" : input.data.eventHasPrevious ? "EVENTS ↑" : input.data.eventHasNext ? "EVENTS ↓" : "EVENTS";
      return [hint(chatLabel, input.data.chatHasPrevious ? "back" : "forward"), chatLine(lines, 0), chatLine(lines, 1), hint(eventLabel, input.data.eventHasPrevious ? "back" : "forward")];
    }
  }
}

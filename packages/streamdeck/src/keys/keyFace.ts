/**
 * Structured composition of what a key shows — the "what to draw" contract the
 * canvas rasteriser consumes to produce a JPEG (or a solid fill).
 *
 * This is the key analogue of the touch strip's `stripLayout`: a pure,
 * pixel-independent description of a key's visual elements derived from the
 * #1350 descriptor (`../keys.js`) — vendor badge, ticket number, a two-line
 * title, and the
 * bucket-appropriate footer. It deliberately does NOT rasterise; the device
 * path's canvas encoder turns a {@link KeyFace} into pixels and the JPEG the
 * `0x07` chunker uploads. Keeping composition separate keeps it deterministic
 * and unit-testable without a canvas.
 */
import {
  type AgentKey,
  type Footer,
  type KeyDescriptor,
  type Vendor,
} from "../keys.js";
import { BLACK, type RgbColor } from "./keyFill.js";

/** The two title rows a key renders; either may be empty. */
export type TitleLines = readonly [string, string];

/** Composed footer face; mirrors the descriptor footer discriminants. */
export type FooterFace = Footer;

/** A composed agent key: everything the canvas needs to draw one agent. */
export interface AgentKeyFace {
  readonly kind: "agent";
  readonly face: string;
  readonly accent: string;
  readonly glow: string;
  /** Pulse period in seconds, or `null` for a steady (non-pulsing) key. */
  readonly pulseSeconds: number | null;
  readonly vendor: Vendor;
  /** Build Order lane selecting the key's line-art icon. */
  readonly icon: string;
  /** Which of the three key surfaces this slot belongs to. */
  readonly role: AgentKey["role"];
  /** Command sub-label, or an event key's direction badge. */
  readonly subLabel: string;
  /** Relative timestamp on an event key; empty for other roles. */
  readonly timeLabel: string;
  /** True when this is the event key the strip is currently reading. */
  readonly selected: boolean;
  readonly ticketNumber: string;
  /**
   * The untruncated title. {@link titleLines} is a deterministic, glyph-free
   * split that keeps the render cache honest; a renderer with real font metrics
   * should re-wrap from this instead, which is how the canvas path fits three
   * proportional lines where the character heuristic fits two.
   */
  readonly title: string;
  readonly titleLines: TitleLines;
  readonly priority: boolean;
  readonly footer: FooterFace;
}

/** A composed empty key: painted as a solid blackout via the RGB fast path. */
export interface EmptyKeyFace {
  readonly kind: "empty";
  readonly fill: RgbColor;
}

export type KeyFace = AgentKeyFace | EmptyKeyFace;

/**
 * Default per-line character budget for the two-line title. A soft heuristic
 * for a 120px key with the default face font; the canvas layer may re-wrap with
 * real glyph metrics, but composition needs a deterministic split for the cache
 * to treat unchanged titles as clean.
 */
export const DEFAULT_TITLE_LINE_CHARS = 9;

/**
 * Wrap `title` into exactly two lines of at most `lineChars` characters each,
 * greedily by whole words. Words longer than the budget are hard-split. Content
 * that overflows the second line is truncated with a trailing ellipsis.
 */
export function wrapTitle(title: string, lineChars: number = DEFAULT_TITLE_LINE_CHARS): TitleLines {
  const budget = Math.max(1, Math.floor(lineChars));
  const tokens = title.trim().split(/\s+/).filter((t) => t.length > 0);

  // Hard-split any token longer than the budget so a single long word wraps.
  const words: string[] = [];
  for (const token of tokens) {
    for (let i = 0; i < token.length; i += budget) {
      words.push(token.slice(i, i + budget));
    }
  }

  const lines: [string, string] = ["", ""];
  let row = 0;
  for (const word of words) {
    const line = lines[row];
    const candidate = line.length === 0 ? word : `${line} ${word}`;
    if (candidate.length <= budget) {
      lines[row] = candidate;
      continue;
    }
    if (row === 0) {
      row = 1;
      lines[1] = word;
      continue;
    }
    // Second line is full: truncate with an ellipsis and stop.
    lines[1] = `${lines[1].slice(0, Math.max(0, budget - 1))}…`;
    return lines;
  }
  return lines;
}

/**
 * Compose a #1350 descriptor into a {@link KeyFace}. Empty descriptors become a
 * black RGB fast-path fill; agent descriptors carry through the bucket style,
 * vendor, ticket number, wrapped title, priority flag, and footer.
 */
export function composeKeyFace(
  descriptor: KeyDescriptor,
  lineChars: number = DEFAULT_TITLE_LINE_CHARS,
): KeyFace {
  if (descriptor.kind === "empty") {
    return { kind: "empty", fill: BLACK };
  }
  return composeAgentFace(descriptor, lineChars);
}

function composeAgentFace(agent: AgentKey, lineChars: number): AgentKeyFace {
  return {
    kind: "agent",
    face: agent.style.face,
    accent: agent.style.accent,
    glow: agent.style.glow,
    pulseSeconds: agent.style.pulseSeconds ?? null,
    vendor: agent.vendor,
    icon: agent.icon,
    role: agent.role,
    subLabel: agent.subLabel,
    timeLabel: agent.timeLabel,
    selected: agent.selected,
    ticketNumber: agent.identifier,
    title: agent.title,
    titleLines: wrapTitle(agent.title, lineChars),
    priority: agent.priority,
    footer: agent.footer,
  };
}

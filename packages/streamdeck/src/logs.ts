/**
 * Pure event-flattening and scroll-window logic for Stream Deck logs mode.
 *
 * No I/O, no timers, no hardware. All functions are pure transforms over the
 * types below.
 */

// ---------------------------------------------------------------------------
// Input types — the event list provided by the agent event feed
// ---------------------------------------------------------------------------

export type Direction = "EMIT" | "CONSUME" | "AGENT" | "SYSTEM" | "INFO";

export interface TranscriptMessage {
  type: "message";
  who: "agent" | "tool" | "ci" | "you";
  text: string;
}

export interface TranscriptDiff {
  type: "diff";
  path: string;
  additions: number;
  deletions: number;
  /** First meaningful changed line from the unified diff, if present. */
  line?: string;
}

export type TranscriptEntry = TranscriptMessage | TranscriptDiff;

export interface LogEvent {
  direction: Direction;
  text: string;
  relativeTime: string;
  entries: readonly TranscriptEntry[];
}

// ---------------------------------------------------------------------------
// Flat entry types — the scroll-window sequence
// ---------------------------------------------------------------------------

export interface FlatHeader {
  kind: "event-header";
  direction: Direction;
  text: string;
  relativeTime: string;
}

export interface FlatMessage {
  kind: "message";
  who: "agent" | "tool" | "ci" | "you";
  text: string;
}

export interface FlatDiff {
  kind: "diff";
  path: string;
  additions: number;
  deletions: number;
  line?: string;
  /** Leading character of `line`, present only when `line` starts with + or -. */
  lineSign?: "+" | "-";
}

export type FlatEntry = FlatHeader | FlatMessage | FlatDiff;

// ---------------------------------------------------------------------------
// Flattening
// ---------------------------------------------------------------------------

export interface FlattenResult {
  /** The flattened sequence, oldest-first. */
  flat: readonly FlatEntry[];
  /**
   * For each event (in input order), the index in `flat` where its header
   * landed. Length equals the number of input events.
   */
  headerIndices: readonly number[];
  /**
   * Maximum valid chatIndex for a 2-line window:
   * `max(0, flat.length - 2)`.
   */
  chatMax: number;
  /**
   * chatIndex that shows the newest content — always equals `chatMax`.
   * Exported so callers can hand it to `StreamDeckEventProjection`.
   */
  newestChatIndex: number;
}

/**
 * Flattens an event list (provided newest-first by the API) into an
 * oldest-first sequence of flat entries. Each event contributes one header
 * followed by its transcript entries in order.
 *
 * Returns an explicit empty result rather than crashing when the list is
 * empty.
 */
export const flattenEvents = (events: readonly LogEvent[]): FlattenResult => {
  if (events.length === 0) {
    return { flat: [], headerIndices: [], chatMax: 0, newestChatIndex: 0 };
  }

  const flat: FlatEntry[] = [];
  // One entry per input event; we fill these while walking in reverse so the
  // index aligns with the original input position.
  const headerIndices: number[] = new Array(events.length);

  // Iterate in reverse so oldest lands first in `flat`.
  for (let i = events.length - 1; i >= 0; i--) {
    const event = events[i];
    // Map from input index to flat position.
    headerIndices[i] = flat.length;

    flat.push({
      kind: "event-header",
      direction: event.direction,
      text: event.text,
      relativeTime: event.relativeTime,
    });

    for (const entry of event.entries) {
      if (entry.type === "diff") {
        const lineSign = entry.line?.startsWith("+") ? "+" : entry.line?.startsWith("-") ? "-" : undefined;
        const flatDiff: FlatDiff = {
          kind: "diff",
          path: entry.path,
          additions: entry.additions,
          deletions: entry.deletions,
        };
        if (entry.line !== undefined) flatDiff.line = entry.line;
        if (lineSign !== undefined) flatDiff.lineSign = lineSign;
        flat.push(flatDiff);
      } else {
        flat.push({ kind: "message", who: entry.who, text: entry.text });
      }
    }
  }

  const chatMax = Math.max(0, flat.length - 2);
  return { flat, headerIndices, chatMax, newestChatIndex: chatMax };
};

// ---------------------------------------------------------------------------
// 2-line scroll window
// ---------------------------------------------------------------------------

/**
 * Returns the two (or fewer) flat entries visible at the given `chatIndex`.
 * Safe at both ends: never throws, never returns more than two entries.
 */
export const chatWindow = (flat: readonly FlatEntry[], chatIndex: number): readonly FlatEntry[] =>
  flat.slice(chatIndex, chatIndex + 2);

// ---------------------------------------------------------------------------
// 8-key event window visibility
// ---------------------------------------------------------------------------

/**
 * Adjusts `windowStart` so that `selection` is visible inside an 8-key
 * window, then clamps to `[0, maxStart]`.
 *
 * Rules:
 * - If `selection` is before the window, move the start to `selection`.
 * - If `selection` is past `windowStart + 7`, set start to
 *   `min(selection - 7, maxStart)`.
 * - Always clamp the result to `[0, maxStart]`.
 */
export const ensureVisible = (windowStart: number, selection: number, eventCount: number): number => {
  const maxStart = Math.max(0, eventCount - 8);

  let start = windowStart;
  if (selection < start) {
    start = selection;
  } else if (selection > start + 7) {
    start = Math.min(selection - 7, maxStart);
  }

  return Math.max(0, Math.min(start, maxStart));
};

// ---------------------------------------------------------------------------
// Hint arrow visibility
// ---------------------------------------------------------------------------

export interface ArrowVisibility {
  left: boolean;
  right: boolean;
}

/**
 * Whether the BACK hint arrows should be visible.
 * Left: there is content before the current chat position.
 * Right: there is content after the current 2-line window.
 */
export const backArrows = (chatIndex: number, chatMax: number): ArrowVisibility => ({
  left: chatIndex > 0,
  right: chatIndex < chatMax,
});

/**
 * Whether the EVENTS hint arrows should be visible.
 * Left: the event window can scroll toward older events.
 * Right: the event window can scroll toward newer events.
 */
export const eventsArrows = (windowStart: number, eventCount: number): ArrowVisibility => {
  const maxStart = Math.max(0, eventCount - 8);
  return {
    left: windowStart > 0,
    right: windowStart < maxStart,
  };
};

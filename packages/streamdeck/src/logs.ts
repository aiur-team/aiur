/**
 * Pure event-flattening and scroll-window logic for Stream Deck logs mode.
 *
 * No I/O, no timers, no hardware. All functions are pure transforms over the
 * types below.
 *
 * ## Input contract
 *
 * `LogEvent` models one agent turn — a badge, a summary body, a timestamp,
 * and its transcript entries. The server-side feed (`AgentEventFeed`) returns
 * a flat list of individual transcript entries grouped by `turn_id`; the
 * adapter that constructs `LogEvent[]` from that flat feed is out of scope for
 * this ticket and will be addressed separately.
 *
 * ## Index-space convention
 *
 * The mode machine tracks three related indices:
 * - `eventSelection` — index into the original (newest-first) input array.
 *   Selects which LogEvent the operator has highlighted in the 8-key window.
 * - `headerIndices[eventSelection]` — the flat index of that event's header
 *   entry. Maps selection → position in the scroll strip.
 * - `chatIndex` — the current scroll offset within `flat`. On logs entry this
 *   is set to `newestChatIndex` (== `chatMax`), which scrolls the strip to
 *   show the most recent content. Navigating events with the dial updates
 *   `chatIndex` to `headerIndices[eventSelection]` so the selected event's
 *   header is in view.
 *
 * Because events[0] is newest, `headerIndices[0]` lands near the end of
 * `flat`, while `headerIndices[events.length - 1]` is 0 (oldest event's
 * header is first in the flat sequence). `chatMax` equals the last valid
 * scroll offset; it is NOT the same as `headerIndices[0]` unless the newest
 * event has exactly one entry.
 */

import type { StreamDeckEventProjection } from "./mode.js";

// ---------------------------------------------------------------------------
// Input types — the event list provided by the agent event feed
// ---------------------------------------------------------------------------

/** Direction badge as emitted by AgentEventFeed. */
export type Badge = "EMIT" | "CONSUME" | "AGENT" | "SYSTEM" | "INFO";

/** Transcript role as stored server-side. */
export type Role = "user" | "assistant" | "system" | "command" | "alert" | "reasoning" | "tool";

export interface TranscriptMessage {
  type: "message";
  role: Role;
  body: string;
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
  badge: Badge;
  /** Summary body for this turn (e.g. first message body or a turn label). */
  body: string;
  timestamp: string;
  entries: readonly TranscriptEntry[];
}

// ---------------------------------------------------------------------------
// Flat entry types — the scroll-window sequence
// ---------------------------------------------------------------------------

export interface FlatHeader {
  kind: "event-header";
  badge: Badge;
  body: string;
  timestamp: string;
}

export interface FlatMessage {
  kind: "message";
  role: Role;
  body: string;
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

const CHAT_WINDOW_SIZE = 2;
const EVENTS_WINDOW_SIZE = 8;

/**
 * Maximum characters a body or line field is allowed to contribute to a flat
 * entry. Content past this point is silently truncated; the 2-line strip
 * window does not support multi-line bodies.
 *
 * Embedded newlines are replaced by a single space before this cap is applied
 * so a multi-paragraph body does not blank the strip.
 */
const MAX_BODY_LENGTH = 120;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/** Normalise a body string: collapse newlines to spaces, cap length. */
const clampBody = (s: string): string => {
  const oneLine = s.replace(/\r?\n/g, " ").trim();
  return oneLine.length <= MAX_BODY_LENGTH ? oneLine : oneLine.slice(0, MAX_BODY_LENGTH);
};

// ---------------------------------------------------------------------------
// Flattening
// ---------------------------------------------------------------------------

/**
 * The flat projection produced by `flattenEvents`. Extends
 * `StreamDeckEventProjection` so the mode machine can consume it directly
 * without a separate adapter.
 */
export interface FlattenResult extends StreamDeckEventProjection {
  /** The flattened sequence, oldest-first. */
  flat: readonly FlatEntry[];
  /**
   * For each event (in input order), the index in `flat` where its header
   * landed. Length equals the number of input events.
   *
   * `headerIndices[0]` is the newest event's header; it lands near the **end**
   * of `flat`. `headerIndices[events.length - 1]` is always 0.
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
      badge: event.badge,
      body: clampBody(event.body),
      timestamp: event.timestamp,
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
        if (entry.line !== undefined) flatDiff.line = clampBody(entry.line);
        if (lineSign !== undefined) flatDiff.lineSign = lineSign;
        flat.push(flatDiff);
      } else {
        flat.push({ kind: "message", role: entry.role, body: clampBody(entry.body) });
      }
    }
  }

  const chatMax = Math.max(0, flat.length - CHAT_WINDOW_SIZE);
  return { flat, headerIndices, chatMax, newestChatIndex: chatMax };
};

// ---------------------------------------------------------------------------
// 2-line scroll window
// ---------------------------------------------------------------------------

/**
 * Returns the two (or fewer) flat entries visible at the given `chatIndex`.
 * Clamps `chatIndex` to `[0, chatMax]` before slicing so out-of-range indices
 * never produce a blank strip.
 */
export const chatWindow = (flat: readonly FlatEntry[], chatIndex: number): readonly FlatEntry[] => {
  const chatMax = Math.max(0, flat.length - CHAT_WINDOW_SIZE);
  const clamped = Math.max(0, Math.min(chatIndex, chatMax));
  return flat.slice(clamped, clamped + CHAT_WINDOW_SIZE);
};

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
  const maxStart = Math.max(0, eventCount - EVENTS_WINDOW_SIZE);

  let start = windowStart;
  if (selection < start) {
    start = selection;
  } else if (selection > start + EVENTS_WINDOW_SIZE - 1) {
    start = Math.min(selection - (EVENTS_WINDOW_SIZE - 1), maxStart);
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
  const maxStart = Math.max(0, eventCount - EVENTS_WINDOW_SIZE);
  return {
    left: windowStart > 0,
    right: windowStart < maxStart,
  };
};

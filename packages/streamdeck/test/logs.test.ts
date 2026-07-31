import { describe, expect, it } from "vitest";

import {
  backArrows,
  chatWindow,
  ensureVisible,
  eventsArrows,
  flattenEvents,
  type FlatDiff,
  type FlatEntry,
  type LogEvent,
  type TranscriptDiff,
  type TranscriptMessage,
} from "../src/logs.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const msg = (text: string, who: TranscriptMessage["who"] = "agent"): TranscriptMessage => ({ type: "message", who, text });
const diff = (path: string, additions: number, deletions: number, line?: string): TranscriptDiff => ({
  type: "diff",
  path,
  additions,
  deletions,
  ...(line !== undefined ? { line } : {}),
});

const event = (text: string, entries: LogEvent["entries"] = [], relativeTime = "1m ago"): LogEvent => ({
  direction: "AGENT",
  text,
  relativeTime,
  entries,
});

// ---------------------------------------------------------------------------
// flattenEvents — empty list
// ---------------------------------------------------------------------------

describe("flattenEvents — empty list", () => {
  it("returns an empty result rather than crashing", () => {
    const result = flattenEvents([]);
    expect(result.flat).toEqual([]);
    expect(result.headerIndices).toEqual([]);
    expect(result.chatMax).toBe(0);
    expect(result.newestChatIndex).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// flattenEvents — ordering: oldest-first
// ---------------------------------------------------------------------------

describe("flattenEvents — ordering", () => {
  it("emits header then entries for each event in oldest-first order", () => {
    // API order: [newest, oldest]
    const events: LogEvent[] = [
      event("newer", [msg("newer-entry")]),
      event("older", [msg("older-entry")]),
    ];

    const { flat } = flattenEvents(events);

    expect(flat[0]).toMatchObject({ kind: "event-header", text: "older" });
    expect(flat[1]).toMatchObject({ kind: "message", text: "older-entry" });
    expect(flat[2]).toMatchObject({ kind: "event-header", text: "newer" });
    expect(flat[3]).toMatchObject({ kind: "message", text: "newer-entry" });
  });

  it("records per-event header indices aligned with the input array position", () => {
    const events: LogEvent[] = [
      event("e0", [msg("m0a"), msg("m0b")]),
      event("e1", [msg("m1a")]),
      event("e2", []),
    ];

    const { flat, headerIndices } = flattenEvents(events);

    // Input index 0 is the newest; its header lands last in flat.
    expect(flat[headerIndices[2]]).toMatchObject({ kind: "event-header", text: "e2" });
    expect(flat[headerIndices[1]]).toMatchObject({ kind: "event-header", text: "e1" });
    expect(flat[headerIndices[0]]).toMatchObject({ kind: "event-header", text: "e0" });
  });
});

// ---------------------------------------------------------------------------
// flattenEvents — chatMax and newestChatIndex
// ---------------------------------------------------------------------------

describe("flattenEvents — chatMax", () => {
  it("is 0 when flat list has exactly 1 entry", () => {
    const { chatMax } = flattenEvents([event("only")]);
    expect(chatMax).toBe(0);
  });

  it("is 0 when flat list has exactly 2 entries", () => {
    const { chatMax } = flattenEvents([event("e", [msg("m")])]);
    expect(chatMax).toBe(0);
  });

  it("equals flatLength - 2 for a list longer than 2", () => {
    // header + 2 messages = 3 entries → chatMax = 1
    const { flat, chatMax } = flattenEvents([event("e", [msg("m1"), msg("m2")])]);
    expect(chatMax).toBe(flat.length - 2);
  });

  it("newestChatIndex equals chatMax", () => {
    const { chatMax, newestChatIndex } = flattenEvents([event("e", [msg("m1"), msg("m2"), msg("m3")])]);
    expect(newestChatIndex).toBe(chatMax);
  });
});

// ---------------------------------------------------------------------------
// flattenEvents — entry types
// ---------------------------------------------------------------------------

describe("flattenEvents — message entries", () => {
  it("preserves who and text", () => {
    const { flat } = flattenEvents([event("e", [msg("hello", "you")])]);
    expect(flat[1]).toEqual({ kind: "message", who: "you", text: "hello" });
  });
});

describe("flattenEvents — diff entries", () => {
  it("maps a diff with a + line to lineSign +", () => {
    const { flat } = flattenEvents([event("e", [diff("src/foo.ts", 3, 1, "+added line")])]);
    expect(flat[1]).toMatchObject({ kind: "diff", path: "src/foo.ts", additions: 3, deletions: 1, line: "+added line", lineSign: "+" });
  });

  it("maps a diff with a - line to lineSign -", () => {
    const { flat } = flattenEvents([event("e", [diff("src/bar.ts", 0, 2, "-removed line")])]);
    expect(flat[1]).toMatchObject({ kind: "diff", lineSign: "-" });
  });

  it("omits lineSign when line does not start with + or -", () => {
    const { flat } = flattenEvents([event("e", [diff("src/baz.ts", 1, 0, " context line")])]);
    expect((flat[1] as FlatDiff).lineSign).toBeUndefined();
  });

  it("omits line and lineSign when no line is provided", () => {
    const { flat } = flattenEvents([event("e", [diff("src/qux.ts", 5, 2)])]);
    expect((flat[1] as FlatDiff).line).toBeUndefined();
    expect((flat[1] as FlatDiff).lineSign).toBeUndefined();
  });

  it("preserves path, additions, and deletions", () => {
    const { flat } = flattenEvents([event("e", [diff("a/b.ts", 10, 4)])]);
    expect(flat[1]).toMatchObject({ kind: "diff", path: "a/b.ts", additions: 10, deletions: 4 });
  });
});

// ---------------------------------------------------------------------------
// chatWindow
// ---------------------------------------------------------------------------

describe("chatWindow", () => {
  const flat: FlatEntry[] = [
    { kind: "message", who: "agent", text: "a" },
    { kind: "message", who: "agent", text: "b" },
    { kind: "message", who: "agent", text: "c" },
  ];

  it("returns the two entries at chatIndex", () => {
    expect(chatWindow(flat, 0)).toEqual([flat[0], flat[1]]);
    expect(chatWindow(flat, 1)).toEqual([flat[1], flat[2]]);
  });

  it("returns one entry at the end of a short list", () => {
    expect(chatWindow(flat, 2)).toEqual([flat[2]]);
  });

  it("returns an empty array for an empty flat list", () => {
    expect(chatWindow([], 0)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// ensureVisible
// ---------------------------------------------------------------------------

describe("ensureVisible", () => {
  it("moves windowStart back when selection is before it", () => {
    expect(ensureVisible(5, 2, 20)).toBe(2);
  });

  it("moves windowStart forward when selection is past windowStart + 7", () => {
    // selection = 10, windowStart = 0, maxStart = 20 - 8 = 12 → min(10 - 7, 12) = 3
    expect(ensureVisible(0, 10, 20)).toBe(3);
  });

  it("does not change windowStart when selection is already visible", () => {
    expect(ensureVisible(3, 7, 20)).toBe(3);
    expect(ensureVisible(3, 3, 20)).toBe(3);
    expect(ensureVisible(3, 10, 20)).toBe(3);
  });

  it("clamps windowStart to 0 when it would go negative", () => {
    expect(ensureVisible(0, 0, 20)).toBe(0);
  });

  it("clamps windowStart to maxStart at the upper bound", () => {
    // eventCount = 8 → maxStart = 0
    expect(ensureVisible(0, 7, 8)).toBe(0);
    // selection = 15, large jump on a 10-event list → maxStart = 2, min(8, 2) = 2
    expect(ensureVisible(0, 15, 10)).toBe(2);
  });

  it("clamps to 0 when eventCount is less than 8", () => {
    expect(ensureVisible(0, 3, 5)).toBe(0);
    expect(ensureVisible(0, 0, 1)).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Arrow visibility — backArrows
// ---------------------------------------------------------------------------

describe("backArrows", () => {
  it("shows no arrows at the only valid position when chatMax is 0", () => {
    expect(backArrows(0, 0)).toEqual({ left: false, right: false });
  });

  it("shows only right when at the start", () => {
    expect(backArrows(0, 5)).toEqual({ left: false, right: true });
  });

  it("shows only left when at chatMax", () => {
    expect(backArrows(5, 5)).toEqual({ left: true, right: false });
  });

  it("shows both when in the middle", () => {
    expect(backArrows(3, 5)).toEqual({ left: true, right: true });
  });
});

// ---------------------------------------------------------------------------
// Arrow visibility — eventsArrows
// ---------------------------------------------------------------------------

describe("eventsArrows", () => {
  it("shows no arrows when all events fit in the window", () => {
    expect(eventsArrows(0, 4)).toEqual({ left: false, right: false });
    expect(eventsArrows(0, 8)).toEqual({ left: false, right: false });
  });

  it("shows only right when at the top of a long list", () => {
    expect(eventsArrows(0, 10)).toEqual({ left: false, right: true });
  });

  it("shows only left when at maxStart", () => {
    // eventCount = 10 → maxStart = 2
    expect(eventsArrows(2, 10)).toEqual({ left: true, right: false });
  });

  it("shows both when in the middle of a long list", () => {
    expect(eventsArrows(1, 10)).toEqual({ left: true, right: true });
  });
});

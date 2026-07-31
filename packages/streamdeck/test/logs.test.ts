import { describe, expect, it } from "vitest";

import {
  backArrows,
  chatWindow,
  ensureVisible,
  eventsArrows,
  flattenEvents,
  type Badge,
  type FlatDiff,
  type FlatEntry,
  type LogEvent,
  type TranscriptDiff,
  type TranscriptMessage,
} from "../src/logs.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const msg = (body: string, role: TranscriptMessage["role"] = "assistant"): TranscriptMessage => ({ type: "message", role, body });
const diff = (path: string, additions: number, deletions: number, line?: string): TranscriptDiff => ({
  type: "diff",
  path,
  additions,
  deletions,
  ...(line !== undefined ? { line } : {}),
});

const event = (
  body: string,
  entries: LogEvent["entries"] = [],
  badge: Badge = "AGENT",
  timestamp = "2026-01-01T00:00:00Z",
): LogEvent => ({ badge, body, timestamp, entries });

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

    expect(flat[0]).toMatchObject({ kind: "event-header", body: "older" });
    expect(flat[1]).toMatchObject({ kind: "message", body: "older-entry" });
    expect(flat[2]).toMatchObject({ kind: "event-header", body: "newer" });
    expect(flat[3]).toMatchObject({ kind: "message", body: "newer-entry" });
  });

  it("records exact per-event header indices aligned with the input array position", () => {
    // events[0]=newest(e0): 2 msgs → header at flat[3]; events[1](e1): 1 msg → header at flat[1]; events[2]=oldest(e2): 0 msgs → header at flat[0]
    const events: LogEvent[] = [
      event("e0", [msg("m0a"), msg("m0b")]),
      event("e1", [msg("m1a")]),
      event("e2", []),
    ];

    const { flat, headerIndices } = flattenEvents(events);

    // e2 (oldest) lands first: flat[0]
    expect(headerIndices[2]).toBe(0);
    expect(flat[0]).toMatchObject({ kind: "event-header", body: "e2" });

    // e1 lands at flat[1] (after e2's single header)
    expect(headerIndices[1]).toBe(1);
    expect(flat[1]).toMatchObject({ kind: "event-header", body: "e1" });

    // e0 (newest) lands at flat[3] (after e2 header + e1 header + e1 msg)
    expect(headerIndices[0]).toBe(3);
    expect(flat[3]).toMatchObject({ kind: "event-header", body: "e0" });
  });

  it("handles a mix of message and diff entries within one event", () => {
    const events: LogEvent[] = [
      event("turn", [msg("body text"), diff("src/a.ts", 2, 1, "+new line")]),
    ];
    const { flat } = flattenEvents(events);

    expect(flat).toHaveLength(3);
    expect(flat[0]).toMatchObject({ kind: "event-header" });
    expect(flat[1]).toMatchObject({ kind: "message", body: "body text" });
    expect(flat[2]).toMatchObject({ kind: "diff", path: "src/a.ts", lineSign: "+" });
  });
});

// ---------------------------------------------------------------------------
// flattenEvents — badge variants
// ---------------------------------------------------------------------------

describe("flattenEvents — badge variants", () => {
  it.each(["EMIT", "CONSUME", "AGENT", "SYSTEM", "INFO"] as Badge[])(
    "passes badge %s through to the flat header",
    (badge) => {
      const { flat } = flattenEvents([event("e", [], badge)]);
      expect(flat[0]).toMatchObject({ kind: "event-header", badge });
    },
  );
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
  it("preserves role and body", () => {
    const { flat } = flattenEvents([event("e", [msg("hello", "user")])]);
    expect(flat[1]).toEqual({ kind: "message", role: "user", body: "hello" });
  });

  it("collapses embedded newlines in body to spaces", () => {
    const { flat } = flattenEvents([event("e", [msg("line one\nline two")])]);
    expect((flat[1] as { kind: string; body: string }).body).toBe("line one line two");
  });

  it("truncates body exceeding MAX_BODY_LENGTH", () => {
    const long = "x".repeat(200);
    const { flat } = flattenEvents([event("e", [msg(long)])]);
    expect((flat[1] as { kind: string; body: string }).body.length).toBe(120);
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
// flattenEvents — structural binding: FlattenResult satisfies StreamDeckEventProjection
// ---------------------------------------------------------------------------

describe("flattenEvents — StreamDeckEventProjection compatibility", () => {
  it("result carries newestChatIndex required by StreamDeckEventProjection", () => {
    const result = flattenEvents([event("e")]);
    // Assignability verified at compile time via `extends`; this runtime check
    // confirms the field is present and numeric.
    expect(typeof result.newestChatIndex).toBe("number");
  });
});

// ---------------------------------------------------------------------------
// chatWindow
// ---------------------------------------------------------------------------

describe("chatWindow", () => {
  const flat: FlatEntry[] = [
    { kind: "message", role: "assistant", body: "a" },
    { kind: "message", role: "assistant", body: "b" },
    { kind: "message", role: "assistant", body: "c" },
  ];

  it("returns the two entries at chatIndex", () => {
    expect(chatWindow(flat, 0)).toEqual([flat[0], flat[1]]);
    expect(chatWindow(flat, 1)).toEqual([flat[1], flat[2]]);
  });

  it("returns one entry when the flat list has only one entry", () => {
    const singleEntry: FlatEntry[] = [{ kind: "message", role: "assistant", body: "only" }];
    expect(chatWindow(singleEntry, 0)).toEqual([singleEntry[0]]);
  });

  it("returns an empty array for an empty flat list", () => {
    expect(chatWindow([], 0)).toEqual([]);
  });

  it("clamps a negative chatIndex to 0", () => {
    expect(chatWindow(flat, -1)).toEqual([flat[0], flat[1]]);
  });

  it("clamps an over-bounds chatIndex to chatMax", () => {
    // chatMax = 3 - 2 = 1; index 99 should be treated as 1
    expect(chatWindow(flat, 99)).toEqual([flat[1], flat[2]]);
  });

  it("clamps chatIndex to chatMax even at chatMax + 5", () => {
    const twoEntry: FlatEntry[] = [
      { kind: "message", role: "assistant", body: "x" },
      { kind: "message", role: "assistant", body: "y" },
    ];
    // chatMax = 0; any index should return [x, y]
    expect(chatWindow(twoEntry, 5)).toEqual(twoEntry);
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

  it("clamps to 0 for a negative selection", () => {
    expect(ensureVisible(0, -1, 20)).toBe(0);
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

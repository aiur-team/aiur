import { createCanvas, type SKRSContext2D } from "@napi-rs/canvas";
import { describe, expect, it } from "vitest";

import { ageLabel, drawSegmentContent } from "../../src/art/segments.js";
import type { TranscriptRow } from "../../src/channel.js";

const EMIT = "#9fd0ff";
const AGENT = "#9fd0ff";
const SYSTEM = "#ffcf87";
const INFO = "#c2c6cf";
const ADD = "#88e0a6";
const DEL = "#ff9a90";
const MUTED = "rgba(240,242,246,0.72)";

interface Ink {
  readonly text: string;
  readonly fill: string;
}

/**
 * Paints one segment and records every string drawn with the colour it was
 * drawn in. The device only ever shows pixels, so the assertions have to run
 * against what the painter actually put on the canvas.
 */
const paint = (row: TranscriptRow | null, now = Date.parse("2026-08-13T03:00:00Z")): Ink[] => {
  const context = createCanvas(200, 100).getContext("2d");
  const ink: Ink[] = [];
  const original = context.fillText.bind(context) as SKRSContext2D["fillText"];
  context.fillText = ((text: string, x: number, y: number) => {
    ink.push({ text, fill: String(context.fillStyle) });
    return original(text, x, y);
  }) as SKRSContext2D["fillText"];
  drawSegmentContent(context, { kind: "chat", row }, now);
  return ink;
};

const drew = (ink: Ink[], text: string): Ink | undefined => ink.find((entry) => entry.text === text);

describe("ageLabel", () => {
  const now = Date.parse("2026-08-13T03:00:00Z");
  it("reads a past instant as a compact age", () => {
    expect(ageLabel("2026-08-13T02:59:30Z", now)).toBe("now");
    expect(ageLabel("2026-08-13T02:57:00Z", now)).toBe("3m");
    expect(ageLabel("2026-08-13T01:00:00Z", now)).toBe("2h");
    expect(ageLabel("2026-08-11T03:00:00Z", now)).toBe("2d");
  });

  it("has no label for a missing or unparseable timestamp", () => {
    expect(ageLabel(null, now)).toBeNull();
    expect(ageLabel("whenever", now)).toBeNull();
  });
});

describe("chat segment", () => {
  it("paints an event header with its badge colour, body and age", () => {
    const ink = paint({ kind: "event_header", badge: "EMIT", body: "Dependency cleared", timestamp: "2026-08-13T02:57:00Z" });
    expect(drew(ink, "EMIT")?.fill).toBe(EMIT);
    expect(drew(ink, "Dependency cleared")).toBeDefined();
    expect(drew(ink, "3m")).toBeDefined();
  });

  it("falls back to the INFO colour for a badge outside the contract", () => {
    const ink = paint({ kind: "event_header", badge: "SHOUT", body: "unknown badge", timestamp: null });
    expect(drew(ink, "SHOUT")?.fill).toBe(INFO);
  });

  // A diff carries no body, so the old single-string rendering printed the
  // literal "[INFO]" here and showed neither the path nor the counts.
  it("paints a diff's path and tinted counts, never a placeholder", () => {
    const ink = paint({ kind: "diff", path: "lib/a.ex", additions: 3, deletions: 1, line: null });
    expect(drew(ink, "lib/a.ex")).toBeDefined();
    expect(drew(ink, "+3")?.fill).toBe(ADD);
    expect(drew(ink, "-1")?.fill).toBe(DEL);
    expect(ink.some((entry) => entry.text.includes("[INFO]"))).toBe(false);
  });

  it("tints a diff line by its leading sign, leaving context lines neutral", () => {
    expect(drew(paint({ kind: "diff", path: "a", additions: 1, deletions: 0, line: "+  added" }), "+  added")?.fill).toBe(ADD);
    expect(drew(paint({ kind: "diff", path: "a", additions: 0, deletions: 1, line: "-  removed" }), "-  removed")?.fill).toBe(DEL);
    expect(drew(paint({ kind: "diff", path: "a", additions: 0, deletions: 0, line: "   context" }), "   context")?.fill).toBe(MUTED);
  });

  it("paints a message's speaker in its contract colour", () => {
    const ink = paint({ kind: "message", role: "assistant", body: "unblocking the refactor" });
    expect(drew(ink, "ASSISTANT")?.fill).toBe(AGENT);
    expect(drew(ink, "unblocking the refactor")).toBeDefined();
  });

  // SYSTEM is the only speaker colour that no other role maps to, so this is
  // the case that actually proves the role table rather than a shared hex.
  it("paints tool and system speakers in the SYSTEM colour", () => {
    expect(drew(paint({ kind: "message", role: "tool", body: "x" }), "TOOL")?.fill).toBe(SYSTEM);
    expect(drew(paint({ kind: "message", role: "system", body: "x" }), "SYSTEM")?.fill).toBe(SYSTEM);
    expect(drew(paint({ kind: "message", role: "ci", body: "x" }), "CI")?.fill).toBe(ADD);
  });

  // The badge is a free string on the wire; a long one must not overprint the
  // age, and a zero or negative budget must not fall back to a bare ellipsis.
  it("clips an over-long badge instead of overprinting the age", () => {
    const ink = paint({ kind: "event_header", badge: "E".repeat(80), body: "long badge", timestamp: "2026-08-13T02:57:00Z" });
    expect(drew(ink, "3m")).toBeDefined();
    const badge = ink.find((entry) => entry.text.startsWith("EEE"));
    expect(badge?.text.endsWith("…")).toBe(true);
  });

  it("paints an unknown speaker in the INFO colour", () => {
    expect(drew(paint({ kind: "message", role: "oracle", body: "hi" }), "ORACLE")?.fill).toBe(INFO);
  });

  it("draws no text at all for a slot past the end of the transcript", () => {
    expect(paint(null)).toEqual([]);
  });

  it("ellipsizes text too wide for the region", () => {
    const body = "a very long agent message that cannot possibly fit inside two hundred pixels";
    const ink = paint({ kind: "message", role: "assistant", body });
    const drawn = ink.find((entry) => entry.text.endsWith("…"));
    expect(drawn).toBeDefined();
    expect(drawn?.text.length).toBeLessThan(body.length);
  });
});

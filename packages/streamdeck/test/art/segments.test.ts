import { createCanvas, type SKRSContext2D } from "@napi-rs/canvas";
import { describe, expect, it } from "vitest";

import { ageLabel, drawSegmentContent, resetLabel } from "../../src/art/segments.js";
import type { TranscriptRow } from "../../src/channel.js";
import type { SegmentContent } from "../../src/touchStrip/stripLayout.js";
import type { ProviderSegmentModel } from "../../src/touchStrip/providerSegment.js";
import type { SummaryModel } from "../../src/touchStrip/summarySegment.js";

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

const NOW = Date.parse("2026-08-13T03:00:00Z");

/** The segment background; every other pixel counts as something painted. */
const BACKGROUND: readonly [number, number, number] = [0x0f, 0x12, 0x16];

interface Render {
  /** Every string the painter drew, with the fill it used. */
  readonly ink: Ink[];
  /** Pixels that are not the flat background, i.e. proof something was drawn. */
  readonly inked: number;
  /** The finished 200x100 region, for comparing two renders. */
  readonly pixels: Uint8ClampedArray;
}

/**
 * Paints one segment and records every string drawn with the colour it was
 * drawn in. The device only ever shows pixels, so the assertions have to run
 * against what the painter actually put on the canvas.
 */
const render = (content: SegmentContent, now = NOW): Render => {
  const context = createCanvas(200, 100).getContext("2d");
  const ink: Ink[] = [];
  const original = context.fillText.bind(context) as SKRSContext2D["fillText"];
  context.fillText = ((text: string, x: number, y: number) => {
    ink.push({ text, fill: String(context.fillStyle) });
    return original(text, x, y);
  }) as SKRSContext2D["fillText"];
  drawSegmentContent(context, content, now);

  // The divider stroke on the right edge is painted for every segment, so the
  // rightmost column is excluded from the ink count: it would otherwise report
  // a segment that drew nothing at all as inked.
  const { data } = context.getImageData(0, 0, 199, 100);
  let inked = 0;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i] !== BACKGROUND[0] || data[i + 1] !== BACKGROUND[1] || data[i + 2] !== BACKGROUND[2]) inked += 1;
  }
  return { ink, inked, pixels: data };
};

const paint = (row: TranscriptRow | null, now = NOW): Ink[] => render({ kind: "chat", row }, now).ink;

const drew = (ink: Ink[], text: string): Ink | undefined => ink.find((entry) => entry.text === text);

const summary = (build: SummaryModel["build"]): SegmentContent => ({
  kind: "summary",
  model: { live: 7, remaining: 25, build },
});

const provider = (model: Partial<ProviderSegmentModel>): SegmentContent => ({
  kind: "provider",
  label: "claude",
  model: { provider: "claude", session: null, weekly: null, freshness: "fresh", hasData: true, ...model },
});

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

  // A diff whose counts are wider than the region leaves a negative width for
  // the path. Drawing nothing is correct; drawing a bare "…" is not.
  it("drops the path entirely when the counts leave it no room", () => {
    const ink = paint({ kind: "diff", path: "src/lib/aiur/orchestrator.ex", additions: 123_456_789_012_345, deletions: 987_654_321_098_765, line: null });
    expect(ink.some((entry) => entry.text.includes("orchestrator"))).toBe(false);
    expect(ink.some((entry) => entry.text === "…")).toBe(false);
    expect(drew(ink, "+123456789012345")).toBeDefined();
  });
});

describe("resetLabel", () => {
  it("reads a future instant as a compact countdown", () => {
    expect(resetLabel("2026-08-13T03:22:00Z", NOW)).toBe("22m");
    expect(resetLabel("2026-08-13T04:30:00Z", NOW)).toBe("1h 30m");
    expect(resetLabel("2026-08-15T03:00:00Z", NOW)).toBe("2d");
  });

  // A window whose reset has already passed still arrives from the daemon
  // until the next poll; it must read as "now", not as a negative countdown.
  it("reads an elapsed window as 'now'", () => {
    expect(resetLabel("2026-08-13T02:59:00Z", NOW)).toBe("now");
  });

  it("has no label for a missing or unparseable instant", () => {
    expect(resetLabel(null, NOW)).toBeNull();
    expect(resetLabel("soon", NOW)).toBeNull();
  });
});

describe("summary segment", () => {
  it("paints the live count and the build bar", () => {
    const { ink, inked } = render(summary({ completed: 13, total: 32, fraction: 0.4, etaLabel: "58m" }));
    expect(drew(ink, "Summary")).toBeDefined();
    expect(drew(ink, "7")).toBeDefined();
    expect(drew(ink, "Build 40%")).toBeDefined();
    expect(drew(ink, "ETA 58m")).toBeDefined();
    expect(inked).toBeGreaterThan(0);
  });

  it("omits the ETA when the build order has not projected one", () => {
    const { ink } = render(summary({ completed: 13, total: 32, fraction: 0.4, etaLabel: null }));
    expect(drew(ink, "Build 40%")).toBeDefined();
    expect(ink.some((entry) => entry.text.startsWith("ETA"))).toBe(false);
  });

  // A fleet with no build order must say so rather than show a 0% bar, which
  // reads as a build that has made no progress.
  it("says so when there is no build order, and draws no bar", () => {
    const withBuild = render(summary({ completed: 13, total: 32, fraction: 0.4, etaLabel: "58m" }));
    const without = render(summary(null));
    expect(drew(without.ink, "No build order")).toBeDefined();
    expect(without.ink.some((entry) => entry.text.startsWith("Build"))).toBe(false);
    expect(without.inked).toBeLessThan(withBuild.inked);
  });
});

describe("provider segment", () => {
  it("paints the provider name, its session percent and its reset", () => {
    const { ink } = render(provider({ session: { usedPercent: 86, resetsAt: "2026-08-13T03:22:00Z" } }));
    expect(drew(ink, "Claude")).toBeDefined();
    expect(drew(ink, "Session")).toBeDefined();
    expect(drew(ink, "86% · 22m")).toBeDefined();
  });

  it("shows the percent alone when the window reported no reset", () => {
    const { ink } = render(provider({ session: { usedPercent: 86, resetsAt: null } }));
    expect(drew(ink, "86%")).toBeDefined();
  });

  // "no reading yet" and "zero usage" are different states; rendering both as
  // 0% is the parity bug this segment exists to avoid.
  it("distinguishes a provider with no reading from one at zero", () => {
    const awaiting = render(provider({ hasData: false }));
    expect(drew(awaiting.ink, "Awaiting data")).toBeDefined();
    expect(awaiting.ink.some((entry) => entry.text.includes("0%"))).toBe(false);

    const zero = render(provider({ session: { usedPercent: 0, resetsAt: null } }));
    expect(drew(zero.ink, "0%")).toBeDefined();
  });

  it("says which window is missing when a reporting provider has no session", () => {
    const { ink } = render(provider({ hasData: true, session: null, weekly: { usedPercent: 12, resetsAt: null } }));
    expect(drew(ink, "No session window")).toBeDefined();
  });

  it("draws a lettered token for a provider with no bundled mark", () => {
    const { inked } = render({
      kind: "provider",
      label: "zephyr",
      model: { provider: "zephyr", session: null, weekly: null, freshness: "fresh", hasData: false },
    });
    expect(inked).toBeGreaterThan(0);
  });
});

describe("pager segment", () => {
  it("paints the label and one dot per window", () => {
    const { ink, inked } = render({
      kind: "pager",
      title: "MORE AGENTS",
      label: "9-16 of 32",
      model: { windowCount: 4, currentWindow: 1, dots: [false, true, false, false], hasMultiple: true },
    });
    expect(drew(ink, "9-16 of 32")).toBeDefined();
    expect(inked).toBeGreaterThan(0);
  });

  // The filled dot is the only thing that tells an operator which window they
  // are on, so a run of dots that all render identically is a real failure.
  it("draws the current window's dot differently from the rest", () => {
    const model = { windowCount: 2, currentWindow: 0, dots: [true, false], hasMultiple: true };
    const first = render({ kind: "pager", title: "MORE AGENTS", label: "1-8", model });
    const second = render({
      kind: "pager",
      title: "MORE AGENTS",
      label: "1-8",
      model: { ...model, currentWindow: 1, dots: [false, true] },
    });
    expect(Array.from(first.pixels)).not.toEqual(Array.from(second.pixels));
  });
});

describe("command-mode segments", () => {
  it("paints the controlled ticket under its caption", () => {
    const { ink } = render({ kind: "controlling", ticketId: "#401" });
    expect(drew(ink, "CONTROLLING")).toBeDefined();
    expect(drew(ink, "#401")).toBeDefined();
  });

  it("paints the agent identity under its caption", () => {
    const { ink } = render({ kind: "agentIdentity", identity: "claude · #401" });
    expect(drew(ink, "AGENT")).toBeDefined();
    expect(drew(ink, "claude · #401")).toBeDefined();
  });

  it("paints the status, the rounded percent and a bar that grows with it", () => {
    const low = render({ kind: "agentProgress", status: "working", percent: 71.6 });
    expect(drew(low.ink, "WORKING")).toBeDefined();
    expect(drew(low.ink, "72%")).toBeDefined();

    const full = render({ kind: "agentProgress", status: "working", percent: 100 });
    expect(full.inked).toBeGreaterThan(low.inked);
  });

  // At 0% the bar must still show its track, but nothing may be filled — a
  // minimum-width fill would read as work already done.
  it("draws the track but no fill at zero percent", () => {
    const empty = render({ kind: "agentProgress", status: "queued", percent: 0 });
    const some = render({ kind: "agentProgress", status: "working", percent: 40 });
    expect(drew(empty.ink, "0%")).toBeDefined();
    expect(empty.inked).toBeGreaterThan(0);
    expect(empty.inked).toBeLessThan(some.inked);
  });
});

describe("hint segment", () => {
  it("points the arrow the way the hint leads", () => {
    expect(drew(render({ kind: "hint", label: "BACK", direction: "back" }).ink, "← BACK")).toBeDefined();
    expect(drew(render({ kind: "hint", label: "EVENTS ↓", direction: "forward" }).ink, "EVENTS ↓ →")).toBeDefined();
  });
});

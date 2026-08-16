import { createCanvas, type SKRSContext2D } from "@napi-rs/canvas";
import { describe, expect, it } from "vitest";

import { ageLabel, drawSegmentContent, PROVIDER_SCROLL_BAND_TOP, resetLabel } from "../../src/art/segments.js";
import type { TranscriptRow } from "../../src/channel.js";
import type { SegmentContent } from "../../src/touchStrip/stripLayout.js";
import type { ProviderSegmentModel } from "../../src/touchStrip/providerSegment.js";
import { PROVIDER_SCROLL_ENCODER, VISIBLE_PROVIDER_ROWS, type ProviderPanelModel, type ProviderPanelRow } from "../../src/touchStrip/providerPanel.js";
import { encoderCenterX, SEGMENT_WIDTH } from "../../src/touchStrip/geometry.js";
import type { SummaryModel } from "../../src/touchStrip/summarySegment.js";
import { agentDetailModel } from "../../src/touchStrip/agentDetail.js";

const EMIT = "#9fd0ff";
const INFO = "#c2c6cf";
const LABEL = "rgba(255,255,255,0.55)";
const ACCENT_LIVE = "#4ade80";

/*
 * The transcript palette, quoted from opencode's default theme exactly as
 * `segments.ts` quotes it. Written out again here rather than imported so a
 * silent edit to the borrowed palette has to be made twice, deliberately.
 */
const TEXT_BRIGHT = "#eeeeee";
const TEXT_MUTED = "#808080";
const PANEL = [0x14, 0x14, 0x14] as const;
const USER_BAR = [0x5c, 0x9c, 0xf5] as const;
const DIFF_ADDED_BG = [0x20, 0x30, 0x3b] as const;
const DIFF_REMOVED_BG = [0x37, 0x22, 0x2c] as const;
const ADDED_SIGN = "#b8db87";
const REMOVED_SIGN = "#e26a75";
const REASONING = "rgba(238,238,238,0.55)";

interface Ink {
  readonly text: string;
  readonly fill: string;
  /** Where the painter put it: a label that names a knob has to land over it. */
  readonly x: number;
  readonly y: number;
}

const NOW = Date.parse("2026-08-13T03:00:00Z");

/** The panel background; every other pixel counts as something painted. */
const BACKGROUND: readonly [number, number, number] = [0x0f, 0x12, 0x16];

interface Render {
  /** Every string the painter drew, with the fill it used. */
  readonly ink: Ink[];
  /** Pixels that are not the flat background, i.e. proof something was drawn. */
  readonly inked: number;
  /** The finished panel, for comparing two renders. */
  readonly pixels: Uint8ClampedArray;
}

/**
 * Paints one panel and records every string drawn with the colour it was drawn
 * in. The device only ever shows pixels, so the assertions have to run against
 * what the painter actually put on the canvas.
 */
const render = (content: SegmentContent, width = 200, now = NOW): Render => {
  const context = createCanvas(width, 100).getContext("2d");
  const ink: Ink[] = [];
  const original = context.fillText.bind(context) as SKRSContext2D["fillText"];
  context.fillText = ((text: string, x: number, y: number) => {
    ink.push({ text, fill: String(context.fillStyle), x, y });
    return original(text, x, y);
  }) as SKRSContext2D["fillText"];
  drawSegmentContent(context, content, width, now);

  // The divider stroke on the right edge is painted for every panel, so the
  // rightmost column is excluded from the ink count: it would otherwise report
  // a panel that drew nothing at all as inked.
  const { data } = context.getImageData(0, 0, width - 1, 100);
  let inked = 0;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i] !== BACKGROUND[0] || data[i + 1] !== BACKGROUND[1] || data[i + 2] !== BACKGROUND[2]) inked += 1;
  }
  return { ink, inked, pixels: data };
};

/** Columns carrying something other than background in `top`..`bottom`. */
const inkedColumns = (pixels: Uint8ClampedArray, width: number, top: number, bottom: number): number[] => {
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
const litColumns = (pixels: Uint8ClampedArray, width: number): number[] => {
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
const chat = (row: TranscriptRow, width = 800): Ink[] => render(chatLog([row]), width).ink;

/** The same, keeping the pixels: the fills and bars carry the speaker. */
const chatPixels = (row: TranscriptRow, width = 800): Render => render(chatLog([row]), width);

/** The colour at a panel coordinate. `render` trims the divider column. */
const pixelAt = (pixels: Uint8ClampedArray, width: number, x: number, y: number): number[] => {
  const index = (y * (width - 1) + x) * 4;
  return [pixels[index], pixels[index + 1], pixels[index + 2]];
};

/** Mid-height of the transcript row at `index`, for sampling its fill. */
const rowMiddle = (index: number): number => 10 + index * 16;

type HeaderRow = Extract<TranscriptRow, { kind: "event_header" }>;
type DiffRow = Extract<TranscriptRow, { kind: "diff" }>;
type MessageRow = Extract<TranscriptRow, { kind: "message" }>;

const header = (over: Partial<HeaderRow> = {}): HeaderRow => ({
  kind: "event_header",
  badge: "EMIT",
  label: "PR merged",
  body: "PR merged",
  timestamp: null,
  ...over,
});

const diffRow = (over: Partial<DiffRow> = {}): DiffRow => ({
  kind: "diff",
  path: "lib/a.ex",
  additions: 0,
  deletions: 0,
  line: null,
  ...over,
});

type DiffLineRow = Extract<TranscriptRow, { kind: "diff_line" }>;

const diffLineRow = (over: Partial<DiffLineRow> = {}): DiffLineRow => ({
  kind: "diff_line",
  sign: " ",
  text: "  unchanged",
  ...over,
});

const message = (over: Partial<MessageRow> = {}): MessageRow => ({
  kind: "message",
  role: "assistant",
  body: "",
  tool: null,
  ...over,
});

const chatLog = (
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

const drew = (ink: Ink[], text: string): Ink | undefined => ink.find((entry) => entry.text === text);

const summary = (build: SummaryModel["build"]): SegmentContent => ({
  kind: "summary",
  model: { live: 7, remaining: 25, build },
});

const providerRow = (label: string, model: Partial<ProviderSegmentModel>): ProviderPanelRow => ({
  label,
  model: { provider: label, session: null, weekly: null, freshness: "fresh", hasData: true, ...model },
});

const provider = (model: Partial<ProviderSegmentModel>): SegmentContent => ({
  kind: "provider",
  row: providerRow("claude", model),
});

const session = (usedPercent: number, resetsAt: string | null = null): Partial<ProviderSegmentModel> => ({
  session: { usedPercent, resetsAt },
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

describe("resetLabel", () => {
  it("reads a future instant as a compact countdown", () => {
    expect(resetLabel("2026-08-13T03:22:00Z", NOW)).toBe("22m");
    expect(resetLabel("2026-08-13T04:30:00Z", NOW)).toBe("1h 30m");
    expect(resetLabel("2026-08-15T03:00:00Z", NOW)).toBe("2d");
  });

  // A window whose reset has already passed still arrives from the daemon until
  // the next poll; it must read as "now", not as a negative countdown.
  it("reads an elapsed window as 'now'", () => {
    expect(resetLabel("2026-08-13T02:59:00Z", NOW)).toBe("now");
  });

  it("has no label for a missing or unparseable instant", () => {
    expect(resetLabel(null, NOW)).toBeNull();
    expect(resetLabel("soon", NOW)).toBeNull();
  });
});

/*
 * The readout mimics opencode's transcript grammar. The assertions below are
 * about that grammar, not about this or that hex: identity is carried by
 * layout — an indent with an empty gutter is the agent talking, a `┃` bar and a
 * panel fill is the operator, a glyph is a tool — and the one thing that must
 * never come back is a bare "ASSISTANT" role word in a left gutter.
 */
describe("chat readout", () => {
  it("prints assistant prose with no role label at all, only an indent", () => {
    const ink = chat(message({ role: "assistant", body: "unblocking the refactor" }));
    const body = drew(ink, "unblocking the refactor");
    expect(body?.fill).toBe(TEXT_BRIGHT);
    // The label-free row is what makes "nothing in the gutter" mean "the agent".
    expect(ink.some((entry) => entry.text.toUpperCase() === "ASSISTANT")).toBe(false);
    // The body is the only thing on the transcript rows; the rest of the ink is
    // the dial hints on the bottom line.
    expect(ink.filter((entry) => entry.y < 90)).toHaveLength(1);
    // An indent, not a gutter column: the body starts near the left edge.
    expect(body?.x).toBeGreaterThan(0);
    expect(body?.x).toBeLessThan(40);
  });

  it("gives an agent turn the same bare treatment and fades reasoning", () => {
    expect(drew(chat(message({ role: "agent", body: "same as assistant" })), "same as assistant")?.fill).toBe(TEXT_BRIGHT);
    expect(drew(chat(message({ role: "reasoning", body: "thinking it over" })), "thinking it over")?.fill).toBe(REASONING);
  });

  // opencode gives bash no colour of its own; the `$` is the whole
  // differentiator, over the panel fill.
  it("marks a command with a $ glyph on a panel fill, not a colour", () => {
    const { ink, pixels } = chatPixels(message({ role: "command", body: "mix test" }));
    expect(drew(ink, "$")?.fill).toBe(TEXT_BRIGHT);
    expect(drew(ink, "mix test")?.fill).toBe(TEXT_BRIGHT);
    expect(pixelAt(pixels, 800, 2, rowMiddle(0))).toEqual([...PANEL]);
  });

  it("gives each tool its own gutter glyph, falling back to the gear", () => {
    const glyphOf = (tool: string | null): string | undefined => {
      const ink = chat(message({ role: "tool", body: "", tool }));
      return ink.find((entry) => entry.x < 30 && entry.text.length === 1)?.text;
    };
    expect(glyphOf("bash")).toBe("$");
    expect(glyphOf("read")).toBe("→");
    expect(glyphOf("write")).toBe("←");
    expect(glyphOf("grep")).toBe("✱");
    expect(glyphOf("web_fetch")).toBe("%");
    expect(glyphOf("sequential-thinking")).toBe("⚙");
    expect(glyphOf(null)).toBe("⚙");
  });

  it("titles a tool rather than shouting it, and names an unnamed one", () => {
    const ink = chat(message({ role: "tool", body: "", tool: "web_fetch" }));
    expect(drew(ink, "Web Fetch")?.fill).toBe(TEXT_MUTED);
    expect(ink.some((entry) => entry.text === "WEB_FETCH")).toBe(false);
    expect(drew(chat(message({ role: "tool", body: "", tool: null })), "Tool")).toBeDefined();
    // A name that is all separators still has to leave a word behind.
    expect(drew(chat(message({ role: "tool", body: "", tool: "read_" })), "Read")).toBeDefined();
  });

  it("brackets tool arguments that read as k=v, and leaves prose alone", () => {
    const args = chat(message({ role: "tool", body: "path=lib/a.ex, limit=20", tool: "read" }));
    expect(drew(args, "[path=lib/a.ex, limit=20]")?.fill).toBe(TEXT_MUTED);

    const prose = chat(message({ role: "tool", body: "ran 42 tests, all green", tool: "bash" }));
    expect(drew(prose, "ran 42 tests, all green")).toBeDefined();
    expect(prose.some((entry) => entry.text.startsWith("["))).toBe(false);

    const empty = chat(message({ role: "tool", body: "", tool: "bash" }));
    expect(empty.some((entry) => entry.text.startsWith("["))).toBe(false);
  });

  // The user turn is the one element opencode gives a visible coloured bar.
  it("gives a user turn a coloured bar and a panel fill", () => {
    const { ink, pixels } = chatPixels(message({ role: "user", body: "ship it" }));
    expect(drew(ink, "ship it")?.fill).toBe(TEXT_BRIGHT);
    expect(pixelAt(pixels, 800, 5, rowMiddle(0))).toEqual([...USER_BAR]);
    expect(pixelAt(pixels, 800, 20, rowMiddle(0))).toEqual([...PANEL]);

    // Assistant prose gets neither, which is what makes the bar mean something.
    const prose = chatPixels(message({ role: "assistant", body: "ship it" }));
    expect(pixelAt(prose.pixels, 800, 5, rowMiddle(0))).toEqual([...BACKGROUND]);
  });

  it("gives system, alert and CI rows a glyph so they are not read as prose", () => {
    const glyphs = ["system", "alert", "ci", "oracle"].map((role) => {
      const ink = chat(message({ role, body: "x" }));
      expect(drew(ink, "x")?.fill).toBe(TEXT_MUTED);
      return ink.find((entry) => entry.x < 30 && entry.text.length === 1)?.text;
    });
    expect(glyphs).toEqual(["·", "!", "✓", "·"]);
  });

  it("paints an event header as a block title: badge, topic, then the age", () => {
    const ink = chat(header({ badge: "EMIT", label: "PR merged", body: "aiur#1821 merged", timestamp: "2026-08-13T02:57:00Z" }));
    expect(drew(ink, "EMIT")?.fill).toBe(EMIT);
    expect(drew(ink, "PR merged")?.fill).toBe(TEXT_BRIGHT);
    expect(drew(ink, "aiur#1821 merged")?.fill).toBe(TEXT_MUTED);
    expect(drew(ink, "3m")?.fill).toBe(TEXT_MUTED);
  });

  // The feed often sets both to the same string; printing it twice reads as a
  // rendering fault rather than as detail.
  it("does not repeat the body when it says the same as the label", () => {
    const ink = chat(header({ label: "Ticket opened", body: "Ticket opened" }));
    expect(ink.filter((entry) => entry.text === "Ticket opened")).toHaveLength(1);
  });

  it("paints an event header with no timestamp at all", () => {
    const ink = chat(header({ label: "Dependency cleared", body: "Dependency cleared", timestamp: null }));
    expect(drew(ink, "Dependency cleared")).toBeDefined();
    expect(ink.some((entry) => entry.text === "3m")).toBe(false);
  });

  it("falls back to the INFO colour for a badge outside the contract", () => {
    expect(drew(chat(header({ badge: "SHOUT" })), "SHOUT")?.fill).toBe(INFO);
  });

  // The badge is a free string on the wire; a long one must not push the topic
  // off the row.
  it("clips an over-long badge rather than letting it eat the row", () => {
    const ink = chat(header({ badge: "E".repeat(80), label: "long badge", body: "long badge", timestamp: "2026-08-13T02:57:00Z" }));
    expect(drew(ink, "3m")).toBeDefined();
    expect(drew(ink, "long badge")).toBeDefined();
    expect(ink.find((entry) => entry.text.startsWith("EEE"))?.text.endsWith("…")).toBe(true);
  });

  // A one-line edit *is* that line, so it gets opencode's sign-tinted full-row
  // fill rather than a header that describes a single change.
  /**
   * Each hunk line is its own row, tinted by its sign, exactly as opencode
   * paints a unified diff. The operator asked to *read* the diff on the strip,
   * so a full-row fill plus a highlight-coloured sign is the whole point.
   */
  it("paints each hunk line as its own sign-tinted row", () => {
    const added = chatPixels(diffLineRow({ sign: "+", text: "  new_call()" }));
    expect(drew(added.ink, "+")?.fill).toBe(ADDED_SIGN);
    expect(drew(added.ink, "  new_call()")?.fill).toBe(TEXT_BRIGHT);
    expect(pixelAt(added.pixels, 800, 2, rowMiddle(0))).toEqual([...DIFF_ADDED_BG]);

    const removed = chatPixels(diffLineRow({ sign: "-", text: "  old_call()" }));
    expect(drew(removed.ink, "-")?.fill).toBe(REMOVED_SIGN);
    expect(drew(removed.ink, "  old_call()")?.fill).toBe(TEXT_BRIGHT);
    expect(pixelAt(removed.pixels, 800, 2, rowMiddle(0))).toEqual([...DIFF_REMOVED_BG]);

    // A context line is deliberately quieter: it is what did not change.
    const context = chatPixels(diffLineRow({ sign: " ", text: "  unchanged" }));
    expect(drew(context.ink, "·")?.fill).toBe(TEXT_MUTED);
    expect(drew(context.ink, "  unchanged")?.fill).toBe(TEXT_MUTED);
    expect(pixelAt(context.pixels, 800, 2, rowMiddle(0))).toEqual([...PANEL]);
  });

  // The header is opencode's block title: a notch, the path, and the counts.
  it("paints the diff header as a block title with right-aligned counts", () => {
    const { ink, pixels } = chatPixels(
      diffRow({ path: "lib/aiur/orchestrator.ex", additions: 3, deletions: 1 }),
    );
    expect(drew(ink, "┃")?.fill).toBe(TEXT_MUTED);
    expect(drew(ink, "lib/aiur/orchestrator.ex")?.fill).toBe(TEXT_MUTED);
    // The counts are Aiur's own addition, kept but muted and right-aligned.
    const counts = drew(ink, "+3 -1");
    expect(counts?.fill).toBe(TEXT_MUTED);
    expect(counts?.x).toBeGreaterThan(700);
    expect(pixelAt(pixels, 800, 2, rowMiddle(0))).toEqual([...PANEL]);
  });

  /**
   * A provider that reports a summary and no hunk still gets its one line
   * shown, on the header row, rather than a header with nothing beneath it.
   */
  it("shows a summary-only diff's single line on the header row", () => {
    const added = chatPixels(diffRow({ additions: 1, line: "+  new_call()" }));
    expect(drew(added.ink, "+  new_call()")?.fill).toBe(ADDED_SIGN);

    const removed = chatPixels(diffRow({ deletions: 1, line: "-  old_call()" }));
    expect(drew(removed.ink, "-  old_call()")?.fill).toBe(REMOVED_SIGN);
  });

  // A diff with no hunk lines still has to render as a header rather than as
  // nothing, and the bare `line` string's own leading character is its sign.
  it("renders a summary-only diff from its bare hunk line, with no ellipsis", () => {
    const plain = chat(diffRow({ additions: 3, deletions: 1, line: null }));
    expect(drew(plain, "lib/a.ex")).toBeDefined();
    expect(drew(plain, "+3 -1")).toBeDefined();
    expect(plain.some((entry) => entry.text === "…")).toBe(false);

    expect(drew(chat(diffRow({ line: "+  added" })), "+  added")?.fill).toBe(ADDED_SIGN);
    expect(drew(chat(diffRow({ line: "-  removed" })), "-  removed")?.fill).toBe(REMOVED_SIGN);
    expect(drew(chat(diffRow({ line: "   context" })), "   context")?.fill).toBe(TEXT_MUTED);
  });

  // The controller addresses transcript rows by index, so every row — header
  // or hunk line — has to occupy exactly one line height. The feed does the
  // unrolling; the renderer never turns one row into several.
  it("keeps every diff row to exactly one painted row", () => {
    const rows: TranscriptRow[] = [
      diffRow({ additions: 2, deletions: 1 }),
      diffLineRow({ sign: "+", text: "one" }),
      diffLineRow({ sign: "-", text: "three" }),
      message({ role: "assistant", body: "after the diff" }),
    ];
    const { ink, pixels } = render(chatLog(rows), 800);
    // Four rows in, four line-heights down — no row painted two.
    expect(drew(ink, "after the diff")?.y).toBe(16 + 3 * 16);
    // Each row's fill stopped at its own row: header panel, added, removed,
    // then the unfilled background an assistant row leaves alone.
    expect(pixelAt(pixels, 800, 2, rowMiddle(0))).toEqual([...PANEL]);
    expect(pixelAt(pixels, 800, 2, rowMiddle(1))).toEqual([...DIFF_ADDED_BG]);
    expect(pixelAt(pixels, 800, 2, rowMiddle(2))).toEqual([...DIFF_REMOVED_BG]);
    expect(pixelAt(pixels, 800, 2, rowMiddle(3))).toEqual([...BACKGROUND]);
  });

  it("shows several rows at once rather than a two-line peephole", () => {
    const rows: TranscriptRow[] = [
      header({ label: "first", body: "first" }),
      message({ role: "assistant", body: "second" }),
      diffRow({ path: "third.ex", additions: 1 }),
      message({ role: "ci", body: "fourth" }),
      message({ role: "system", body: "fifth" }),
    ];
    const { ink } = render(chatLog(rows), 800);
    for (const text of ["first", "second", "third.ex", "fourth", "fifth"]) {
      expect(drew(ink, text)).toBeDefined();
    }
  });

  it("says so when the agent has said nothing yet", () => {
    expect(drew(render(chatLog([]), 800).ink, "No chat yet.")).toBeDefined();
  });

  it("ellipsizes a line too wide for the strip", () => {
    const body = "a very long agent message ".repeat(20);
    const drawn = chat(message({ role: "assistant", body })).find((entry) => entry.text.endsWith("…"));
    expect(drawn).toBeDefined();
    expect(drawn?.text.length).toBeLessThan(body.length);
  });

  // A diff whose counts are wider than the panel leaves a negative width for the
  // path. Drawing nothing is correct; drawing a bare "…" is not.
  it("drops the path entirely when the counts leave it no room", () => {
    const ink = chat(
      diffRow({
        path: "src/lib/aiur/orchestrator.ex",
        additions: 123_456_789_012_345,
        deletions: 987_654_321_098_765,
        line: "+x",
      }),
      200,
    );
    expect(ink.some((entry) => entry.text.includes("orchestrator"))).toBe(false);
    expect(ink.some((entry) => entry.text === "…")).toBe(false);
    expect(drew(ink, "+123456789012345 -987654321098765")).toBeDefined();
  });

  it("shows the dial hints, lit only where there is more to scroll to", () => {
    const both = render(chatLog([], { chatHasNext: true, eventHasPrevious: true }), 800).ink;
    expect(drew(both, "  CHAT ›")?.fill).toBe(ACCENT_LIVE);
    expect(drew(both, "‹ EVENTS  ")?.fill).toBe(ACCENT_LIVE);

    const neither = render(chatLog([]), 800).ink;
    expect(drew(neither, "  CHAT  ")?.fill).toBe(LABEL);
    expect(drew(neither, "  EVENTS  ")?.fill).toBe(LABEL);
  });
});

describe("summary panel", () => {
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

describe("provider panel (two providers)", () => {
  it("paints the provider name, its session percent and its reset", () => {
    const { ink } = render(provider(session(86, "2026-08-13T03:22:00Z")));
    expect(drew(ink, "Claude")).toBeDefined();
    expect(drew(ink, "Session")).toBeDefined();
    expect(drew(ink, "86% · 22m")).toBeDefined();
  });

  it("shows the percent alone when the window reported no reset", () => {
    expect(drew(render(provider(session(86))).ink, "86%")).toBeDefined();
  });

  // "no reading yet" and "zero usage" are different states; rendering both as
  // 0% is the parity bug this panel exists to avoid.
  it("distinguishes a provider with no reading from one at zero", () => {
    const awaiting = render(provider({ hasData: false }));
    expect(drew(awaiting.ink, "Awaiting data")).toBeDefined();
    expect(awaiting.ink.some((entry) => entry.text.includes("0%"))).toBe(false);

    expect(drew(render(provider(session(0))).ink, "0%")).toBeDefined();
  });

  it("says which window is missing when a reporting provider has no session", () => {
    const { ink } = render(provider({ hasData: true, session: null, weekly: { usedPercent: 12, resetsAt: null } }));
    expect(drew(ink, "No session window")).toBeDefined();
  });

  it("draws a lettered token for a provider with no bundled mark", () => {
    expect(render({ kind: "provider", row: providerRow("zephyr", { hasData: false }) }).inked).toBeGreaterThan(0);
  });
});

describe("provider panel (three or more)", () => {
  /** The panel as the layout composes it: the centre two segments, so x=200. */
  const PANEL_X = SEGMENT_WIDTH;

  const wide = (
    rows: readonly ProviderPanelRow[],
    scroll: Partial<Pick<ProviderPanelModel, "total" | "hasAbove" | "hasBelow">> = {},
    originX = PANEL_X,
  ): SegmentContent => ({
    kind: "providers",
    model: { rows, total: rows.length, hasAbove: false, hasBelow: false, ...scroll },
    originX,
  });

  it("paints a row per provider, each keeping its session label, percent and reset", () => {
    const { ink } = render(
      wide([
        providerRow("claude", session(86, "2026-08-13T03:22:00Z")),
        providerRow("codex", session(19)),
        providerRow("deepseek", session(55)),
      ]),
      400,
    );
    expect(drew(ink, "Claude")).toBeDefined();
    expect(drew(ink, "Codex")).toBeDefined();
    expect(drew(ink, "Deepseek")).toBeDefined();
    expect(drew(ink, "Session 86% · 22m")).toBeDefined();
    expect(drew(ink, "Session 19%")).toBeDefined();
  });

  it("keeps every row and the scroll label inside the panel", () => {
    const rows = Array.from({ length: VISIBLE_PROVIDER_ROWS }, (_, index) => providerRow(`p${index}`, session(index * 10)));
    const { pixels } = render(wide(rows, { total: 9, hasAbove: true, hasBelow: true }), 400);
    // The bottom two pixel rows must stay background: content that ran past the
    // panel would be clipped by the canvas and the operator would never see it.
    // Two rows rather than one because the chevrons are the lowest thing drawn.
    const bottom = pixels.subarray(399 * 4 * 98);
    for (let i = 0; i < bottom.length; i += 4) {
      expect([bottom[i], bottom[i + 1], bottom[i + 2]]).toEqual([...BACKGROUND]);
    }
  });

  // The window size lives in providerPanel.ts and the pixel budget that has to
  // hold it lives here. Raising one without retuning the other would clip a row
  // against the canvas edge — a provider silently dropped, which is the exact
  // failure the scroll replaced.
  it("leaves the label band inside the panel for the configured window size", () => {
    expect(PROVIDER_SCROLL_BAND_TOP).toBeLessThan(100);
    // Room for a 10px label plus its chevrons under the last row.
    expect(100 - PROVIDER_SCROLL_BAND_TOP).toBeGreaterThanOrEqual(12);
  });

  // The panel used to derive row height, type size and bar height from the row
  // count, so configuring a fifth provider silently shrank every row to 8px.
  // Rows are now one fixed size and the scroll label never eats into them.
  it("draws the rows at the same size and place whether or not the list scrolls", () => {
    const rows = [providerRow("a", session(10)), providerRow("b", session(20)), providerRow("c", session(30))];
    const fixed = render(wide(rows), 400).pixels;
    const scrolling = render(wide(rows, { total: 8, hasBelow: true }), 400).pixels;
    // Everything above the label band is identical; only the band differs.
    const band = 399 * 4 * PROVIDER_SCROLL_BAND_TOP;
    expect(scrolling.subarray(0, band)).toEqual(fixed.subarray(0, band));
    expect(scrolling.subarray(band)).not.toEqual(fixed.subarray(band));
  });

  it("draws no bar for a provider that reported nothing, so no bar means no data", () => {
    const withData = render(wide([providerRow("a", session(90)), providerRow("b", session(90)), providerRow("c", session(90))]), 400);
    const without = render(wide([providerRow("a", session(90)), providerRow("b", session(90)), providerRow("c", { hasData: false })]), 400);
    expect(drew(without.ink, "Awaiting data")).toBeDefined();
    expect(without.inked).toBeLessThan(withData.inked);
  });

  it("says how many providers there are in total, not how many it is showing", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    expect(drew(render(wide(rows, { total: 5, hasBelow: true }), 400).ink, "5 MODELS")).toBeDefined();
  });

  // A chevron pair that cannot move is an instruction to turn a knob that does
  // nothing, so a fleet that already fits gets no affordance at all.
  it("draws no scroll affordance when every provider is already on screen", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    const { ink, pixels } = render(wide(rows), 400);
    expect(ink.some((entry) => entry.text.includes("MODELS"))).toBe(false);
    expect(inkedColumns(pixels, 400, PROVIDER_SCROLL_BAND_TOP, 100)).toEqual([]);
  });

  // The label names knob 2, so it has to sit over knob 2 — which is the strip's
  // second quarter, not the middle of the panel the label lives in. Measured on
  // the text itself, driven off the same constant the controller routes detents
  // through, so the hint and the control cannot drift apart.
  it("centres the scroll label over its own encoder, not over its panel", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    const { ink } = render(wide(rows, { total: 6, hasAbove: true, hasBelow: true }), 400);
    const label = drew(ink, "6 MODELS");
    expect(label).toBeDefined();

    const context = createCanvas(400, 100).getContext("2d");
    context.font = "700 10px monospace";
    const centre = (label as Ink).x + context.measureText("6 MODELS").width / 2;
    // Panel-local x of the encoder's centre: the panel starts at the strip's
    // first quarter mark, so the panel's own centre would name no knob at all.
    expect(Math.abs(centre - (encoderCenterX(PROVIDER_SCROLL_ENCODER) - PANEL_X))).toBeLessThan(1);
    expect(centre).toBeLessThan(400 / 2);
  });

  // The painter is handed a width, never a position, so a panel drawn somewhere
  // else has to take its label with it rather than aiming at a remembered x.
  it("follows the panel when the layout puts it somewhere else", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    const moved = render(wide(rows, { total: 6, hasBelow: true }, 0), 400).ink;
    const label = drew(moved, "6 MODELS");
    const context = createCanvas(400, 100).getContext("2d");
    context.font = "700 10px monospace";
    const centre = (label as Ink).x + context.measureText("6 MODELS").width / 2;
    expect(Math.abs(centre - encoderCenterX(PROVIDER_SCROLL_ENCODER))).toBeLessThan(1);
  });

  it("lights the chevron on the side that still has providers", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    const top = litColumns(render(wide(rows, { total: 6, hasBelow: true }), 400).pixels, 400);
    const bottom = litColumns(render(wide(rows, { total: 6, hasAbove: true }), 400).pixels, 400);
    const middle = litColumns(render(wide(rows, { total: 6, hasAbove: true, hasBelow: true }), 400).pixels, 400);

    expect(top.length).toBeGreaterThan(0);
    expect(bottom.length).toBeGreaterThan(0);
    // At the top of the list only the "more below" chevron is lit, and it sits
    // on the far side of the label from the "more above" one, so the two ends
    // of the list cannot be confused for each other.
    expect(Math.min(...top)).toBeGreaterThan(Math.max(...bottom));
    // Mid-list both are lit, which is a third distinct state.
    expect(middle.length).toBeGreaterThan(top.length);
    expect(Math.min(...middle)).toBeLessThan(Math.min(...top));
  });

  it("clips a long provider name rather than running it under the reading", () => {
    const rows = [
      providerRow("a-very-long-provider-family-name-indeed-truly", session(50)),
      providerRow("b", session(50)),
      providerRow("c", session(50)),
    ];
    expect(render(wide(rows), 400).ink.some((entry) => entry.text.endsWith("…"))).toBe(true);
  });
});

describe("pager panel", () => {
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

describe("agent detail panel", () => {
  const detail = (agent: Readonly<Record<string, unknown>>): SegmentContent => ({
    kind: "agentDetail",
    model: agentDetailModel(agent),
  });

  it("reads like the agent's key: ticket, full title, percent, bar and BACK", () => {
    const { ink } = render(
      detail({
        identifier: "401",
        title: "Auth refactor and session rotation",
        icon: "key",
        vendor: "claude",
        bucket: "running",
        progress_percent: 72,
      }),
      800,
    );
    expect(drew(ink, "401")).toBeDefined();
    expect(drew(ink, "Auth refactor and session rotation")).toBeDefined();
    expect(drew(ink, "72%")).toBeDefined();
    expect(drew(ink, "RUNNING")).toBeDefined();
    expect(drew(ink, "‹ BACK  ")).toBeDefined();
  });

  it("shows the agent's activity and how long it has been at it", () => {
    const withActivity = render(detail({ identifier: "401", bucket: "running", activity: "waiting_ci", runtime_seconds: 11_240 }), 800);
    expect(drew(withActivity.ink, "Waiting on CI")).toBeDefined();
    expect(drew(withActivity.ink, "ELAPSED")).toBeDefined();
    expect(drew(withActivity.ink, "3h 07m")).toBeDefined();

    // The glyph is drawn, not merely resolved: the label alone would still read
    // correctly with the icon call deleted.
    const withoutGlyph = render(detail({ identifier: "401", bucket: "running", runtime_seconds: 11_240 }), 800);
    expect(withActivity.inked).toBeGreaterThan(withoutGlyph.inked);
  });

  // The daemon sends no activity for an agent with no fresh stage and no
  // actionable wait. Inventing one there would be a lie on a glanceable surface.
  it("omits the activity and the elapsed time when the daemon sent neither", () => {
    const { ink } = render(detail({ identifier: "401", bucket: "running" }), 800);
    expect(ink.some((entry) => entry.text === "ELAPSED")).toBe(false);
    expect(ink.some((entry) => entry.text.startsWith("Waiting"))).toBe(false);
    expect(drew(ink, "RUNNING")).toBeDefined();
  });

  // The bucket crosses the wire as a free string. A state the contract has not
  // learned yet must degrade to its own name, not take the repaint down.
  it("survives a bucket the key-face contract does not define", () => {
    expect(drew(render(detail({ identifier: "401", bucket: "hibernating" }), 800).ink, "HIBERNATING")).toBeDefined();
  });

  // The status is a free string off the wire and shares its baseline with the
  // right-aligned elapsed reading, so it needs a real budget rather than the
  // contract's short labels happening to fit.
  it("clips an over-long status rather than overprinting the elapsed reading", () => {
    const { ink } = render(detail({ identifier: "401", bucket: "h".repeat(200), runtime_seconds: 11_240 }), 800);
    expect(drew(ink, "3h 07m")).toBeDefined();
    expect(ink.find((entry) => entry.text.startsWith("HHH"))?.text.endsWith("…")).toBe(true);
  });

  it("uses one green fill, a solid zero stub, and a brighter completion shade", () => {
    const empty = render(detail({ identifier: "401", bucket: "queued", progress_percent: 0 }), 800);
    const some = render(detail({ identifier: "401", bucket: "running", progress_percent: 60 }), 800);
    const complete = render(detail({ identifier: "401", bucket: "running", progress_percent: 100 }), 800);
    expect(drew(empty.ink, "0%")).toBeDefined();
    expect(empty.inked).toBeGreaterThan(0);
    expect(empty.inked).toBeLessThan(some.inked);
    expect(pixelAt(empty.pixels, 800, 211, 79)).toEqual([63, 185, 80]);
    expect(pixelAt(some.pixels, 800, 300, 79)).toEqual([63, 185, 80]);
    expect(pixelAt(complete.pixels, 800, 300, 79)).toEqual([116, 212, 127]);
  });

  it("keeps unknown progress structurally distinct from a measured zero", () => {
    const unknown = render(detail({ identifier: "401", bucket: "running", progress_percent: null }), 800);
    const zero = render(detail({ identifier: "401", bucket: "running", progress_percent: 0 }), 800);

    expect(drew(unknown.ink, "—")).toBeDefined();
    expect(drew(zero.ink, "0%")).toBeDefined();
    expect(Array.from(unknown.pixels)).not.toEqual(Array.from(zero.pixels));
  });

  it("clips an over-long title rather than running it under the percentage", () => {
    const { ink } = render(detail({ identifier: "401", bucket: "running", title: "word ".repeat(60), progress_percent: 50 }), 800);
    expect(drew(ink, "50%")).toBeDefined();
    expect(ink.some((entry) => entry.text.endsWith("…"))).toBe(true);
  });
});

describe("blank panel", () => {
  // A provider slot with no provider configured for it. An "Awaiting data"
  // label here would claim a provider that does not exist.
  it("draws nothing at all", () => {
    expect(render({ kind: "blank" }).ink).toEqual([]);
  });
});

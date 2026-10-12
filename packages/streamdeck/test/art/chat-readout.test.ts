import { describe, expect, it } from "vitest";

import type { TranscriptRow } from "../../src/channel.js";
import { BACKGROUND, render } from "./renderSegment.js";
import {
  EMIT,
  INFO,
  LABEL,
  ACCENT_LIVE,
  TEXT_BRIGHT,
  TEXT_MUTED,
  PANEL,
  USER_BAR,
  DIFF_ADDED_BG,
  DIFF_REMOVED_BG,
  ADDED_SIGN,
  REMOVED_SIGN,
  COMMAND_COLOUR,
  AGENT_COLOUR,
  LOGS_COLOUR,
  USER_COLOUR,
  chat,
  chatPixels,
  pixelAt,
  rowMiddle,
  header,
  diffRow,
  diffLineRow,
  message,
  chatLog,
  drew,
} from "./segmentFixtures.js";

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
    expect(body?.fill).toBe(AGENT_COLOUR);
    // The label-free row is what makes "nothing in the gutter" mean "the agent".
    expect(ink.some((entry) => entry.text.toUpperCase() === "ASSISTANT")).toBe(false);
    // The body is the only thing on the transcript rows; the rest of the ink is
    // the dial hints on the bottom line.
    expect(ink.filter((entry) => entry.y < 90)).toHaveLength(1);
    // An indent, not a gutter column: the body starts near the left edge.
    expect(body?.x).toBeGreaterThan(0);
    expect(body?.x).toBeLessThan(40);
  });

  it("gives an agent turn the same bare blue and classifies reasoning as a log", () => {
    expect(drew(chat(message({ role: "agent", body: "same as assistant" })), "same as assistant")?.fill).toBe(AGENT_COLOUR);
    // Reasoning is a "logs" row (tan) with a gutter glyph, not faded prose:
    // it is not something the agent said to the operator.
    const reasoning = chat(message({ role: "reasoning", body: "thinking it over" }));
    expect(drew(reasoning, "thinking it over")?.fill).toBe(LOGS_COLOUR);
    expect(reasoning.find((entry) => entry.x < 30 && entry.text.length === 1)?.text).toBe("·");
  });

  // opencode gives bash no colour of its own; the `$` is the whole
  // differentiator, over the panel fill — #1960 adds the command green.
  it("marks a command with a $ glyph on a panel fill, in the command green", () => {
    const { ink, pixels } = chatPixels(message({ role: "command", body: "mix test" }));
    expect(drew(ink, "$")?.fill).toBe(COMMAND_COLOUR);
    expect(drew(ink, "mix test")?.fill).toBe(COMMAND_COLOUR);
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

  // #1960: the tool row shows the command or path, not the tool name. The
  // server's `body` (verb stripped) and `glyph` carry it; the fixture provides
  // them the way the DTO would, and the title is gone.
  it("shows the tool's argument as the row, not the tool name", () => {
    const ink = chat(message({ role: "tool", body: "lib/aiur.ex", tool: "read", rowKind: "command", glyph: "→" }));
    expect(drew(ink, "lib/aiur.ex")?.fill).toBe(COMMAND_COLOUR);
    expect(drew(ink, "→")?.fill).toBe(COMMAND_COLOUR);
    expect(ink.some((entry) => entry.text === "Read" || entry.text === "READ")).toBe(false);

    // Without a server glyph, the renderer falls back to the tool-name map.
    const fallback = chat(message({ role: "tool", body: "src/b.ts", tool: "write" }));
    expect(drew(fallback, "src/b.ts")?.fill).toBe(COMMAND_COLOUR);
    expect(fallback.find((entry) => entry.x < 30 && entry.text.length === 1)?.text).toBe("←");
  });

  // A tool with no scalar argument keeps its name as the body (the deliberate
  // fallback), still in the command green with a glyph, never a k=v bracket.
  it("renders a tool's raw body rather than bracket-arg form", () => {
    const args = chat(message({ role: "tool", body: "path=lib/a.ex, limit=20", tool: "read", rowKind: "command" }));
    expect(drew(args, "path=lib/a.ex, limit=20")?.fill).toBe(COMMAND_COLOUR);
    expect(args.some((entry) => entry.text.startsWith("["))).toBe(false);

    const empty = chat(message({ role: "tool", body: "", tool: "bash" }));
    expect(empty.some((entry) => entry.text.startsWith("["))).toBe(false);
  });

  // The user turn is the one element opencode gives a visible coloured bar.
  it("gives a user turn a coloured bar, a panel fill, and the user purple", () => {
    const { ink, pixels } = chatPixels(message({ role: "user", body: "ship it" }));
    expect(drew(ink, "ship it")?.fill).toBe(USER_COLOUR);
    expect(pixelAt(pixels, 800, 5, rowMiddle(0))).toEqual([...USER_BAR]);
    expect(pixelAt(pixels, 800, 20, rowMiddle(0))).toEqual([...PANEL]);

    // Assistant prose gets neither, which is what makes the bar mean something.
    const prose = chatPixels(message({ role: "assistant", body: "ship it" }));
    expect(pixelAt(prose.pixels, 800, 5, rowMiddle(0))).toEqual([...BACKGROUND]);
  });

  it("gives system, alert and CI rows a glyph in the log tan, not prose ink", () => {
    const glyphs = ["system", "alert", "ci", "oracle"].map((role) => {
      const ink = chat(message({ role, body: "x" }));
      expect(drew(ink, "x")?.fill).toBe(LOGS_COLOUR);
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

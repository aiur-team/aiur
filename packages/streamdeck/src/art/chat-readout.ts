/** The logs-mode chat readout: the transcript painted in opencode's grammar. */
import type { SKRSContext2D } from "@napi-rs/canvas";

import { rowKindOfRole, type ChatKind, type DiffLine, type TranscriptRow } from "../channel.js";
import type { SegmentContent } from "../touchStrip/stripLayout.js";
import {
  BADGE_IDS,
  directionBadgeColor,
  type DirectionBadge,
} from "../key-face-contract.js";
import { ageLabel, fit, rightText } from "./segmentText.js";
import {
  LABEL,
  ACCENT_LIVE,
  PAD,
  HEIGHT,
  EVENT_TEXT_SIZE,
} from "./segmentStyle.js";

const isBadge = (badge: string): badge is DirectionBadge => (BADGE_IDS as readonly string[]).includes(badge);

/**
 * Contract colour for a badge the daemon sent.
 *
 * The badge crosses the wire as a free string, so an unrecognised one falls
 * back to INFO — the neutral badge — rather than throwing and taking the whole
 * strip repaint with it.
 */
const badgeColour = (badge: string): string => directionBadgeColor(isBadge(badge) ? badge : "INFO");

/*
 * ---------------------------------------------------------------------------
 * The logs-mode transcript, in opencode's grammar.
 * ---------------------------------------------------------------------------
 *
 * The readout mimics the opencode TUI's transcript rather than printing a
 * right-aligned role word in a gutter. The single most important thing it
 * borrows is the *absence* of a label: opencode never prints "ASSISTANT:", it
 * carries speaker identity in layout — assistant prose is bare indented text on
 * the page background, and everything that is not assistant prose earns a
 * glyph, a fill, or a bar. A label-free row is therefore the agent talking.
 *
 * COLOURS ARE BORROWED, NOT INVENTED. Every hex in {@link OPENCODE} is taken
 * from opencode's default `opencode` theme. They deliberately do NOT come from
 * `key-face-contract.json`: that contract is Aiur's *fleet-state* palette —
 * bucket accents and direction badges, shared with the dashboard so the two
 * surfaces cannot disagree about what "stuck" looks like. This is a different
 * palette on purpose, quoting another tool's transcript, and mixing the two
 * would make a fleet-state colour mean "removed line" somewhere on the strip.
 * The one exception is the event badge, which stays a direction-badge colour
 * because the badge is Aiur's own concept and the log keys paint the same token.
 */
export const OPENCODE = {
  /** `text` / `markdownText`: assistant prose, command text, diff line text. */
  text: "#eeeeee",
  /** `textMuted`: completed tool calls, block titles, system chatter, the age. */
  textMuted: "#808080",
  /** `backgroundPanel`: the fill behind a user turn, a command, a tool block. */
  backgroundPanel: "#141414",
  /** `secondary`: the default agent colour, i.e. the user turn's `┃` bar. */
  secondary: "#5c9cf5",
  /** `error`: a failed tool call. The feed carries no failure flag yet. */
  error: "#e06c75",
  /** `diffAddedBg` / `diffRemovedBg`: full-row fills behind a unified diff line. */
  diffAddedBg: "#20303b",
  diffRemovedBg: "#37222c",
  /** `diffHighlightAdded` / `diffHighlightRemoved`: the `+`/`-` sign glyphs. */
  diffHighlightAdded: "#b8db87",
  diffHighlightRemoved: "#e26a75",
  /** opencode fades reasoning against its own prose; same layout, less ink. */
  reasoning: "rgba(238,238,238,0.55)",
} as const;

/** Row background per diff sign; context lines get the plain panel fill. */
const DIFF_ROW_FILL: Readonly<Record<DiffLine["sign"], string>> = {
  "+": OPENCODE.diffAddedBg,
  "-": OPENCODE.diffRemovedBg,
  " ": OPENCODE.backgroundPanel,
};

/** Sign-glyph tint per diff sign, brighter than the row fill it sits on. */
const DIFF_SIGN_COLOR: Readonly<Record<DiffLine["sign"], string>> = {
  "+": OPENCODE.diffHighlightAdded,
  "-": OPENCODE.diffHighlightRemoved,
  " ": OPENCODE.textMuted,
};

/**
 * Tool glyphs, opencode's two-column gutter. A tool the map does not name gets
 * the generic gear rather than a guessed glyph.
 */
const TOOL_GLYPHS: Readonly<Record<string, string>> = {
  bash: "$",
  shell: "$",
  run: "$",
  read: "→",
  view: "→",
  edit: "←",
  write: "←",
  patch: "←",
  glob: "✱",
  grep: "✱",
  search: "✱",
  webfetch: "%",
  fetch: "%",
};

/**
 * Glyphs for the roles opencode has no equivalent for. They exist only so a
 * system line, an alert or a CI report cannot be mistaken for assistant prose,
 * which on this surface is defined as the row with nothing in its gutter.
 */
const ROLE_GLYPHS: Readonly<Record<string, string>> = {
  system: "·",
  alert: "!",
  ci: "✓",
};

/**
 * Per-kind row colours, #1960: commands and tool rows are one class, agent
 * prose another, and system/reasoning/alert rows the third. The palette is the
 * emulator's existing logs palette (#1934, borrowed from opencode's default
 * theme and documented there) so the physical deck and the emulator agree —
 * and so the low-contrast hues of the plain opencode `text`/`textMuted`
 * inks do not wash out on a small backlit LCD.
 */
const CHAT_COLOURS: Readonly<Record<ChatKind, string>> = {
  command: "#88e0a6",
  agent: "#9fd0ff",
  logs: "#ffcf87",
  user: "#c69bff",
};

/** Left gutter (glyph column), then the body column: opencode's `paddingLeft: 3`. */
const CHAT_GLYPH_X = PAD;
const CHAT_BODY_X = PAD + 22;
/** The user turn's `┃` bar, at the very left edge. */
const CHAT_BAR_X = 4;
const CHAT_BAR_WIDTH = 2;
/** Widest a badge token may draw before it is clipped. */
const CHAT_BADGE_MAX = 72;
/** First transcript baseline, and the step between rows. */
const CHAT_FIRST_BASELINE = 16;
const CHAT_LINE_HEIGHT = 16;
/** Baseline-to-row-top, so a full-row fill lands on the row it belongs to. */
const CHAT_ROW_RISE = 12;

const CHAT_BADGE_FONT = "700 10px monospace";
const CHAT_GLYPH_FONT = "700 12px monospace";
export const CHAT_BODY_FONT = `600 ${EVENT_TEXT_SIZE}px sans-serif`;
const CHAT_MONO_FONT = `600 ${EVENT_TEXT_SIZE - 1}px monospace`;

/** The row's full-width background: a fill, a diff tint, or a tool block. */
const chatRowFill = (context: SKRSContext2D, width: number, baseline: number, color: string): void => {
  context.fillStyle = color;
  context.fillRect(0, baseline - CHAT_ROW_RISE, width, CHAT_LINE_HEIGHT);
};

/**
 * Draws one clipped run at `x` and reports the width it actually used, so the
 * next run starts after it instead of over it. A negative budget draws nothing
 * and advances by nothing.
 */
const runText = (context: SKRSContext2D, text: string, x: number, baseline: number, color: string, budget: number): number => {
  const clipped = fit(context, text, budget);
  context.fillStyle = color;
  context.fillText(clipped, x, baseline);
  return context.measureText(clipped).width;
};

/** Gutter glyph for a named tool; `⚙` for one the map does not know. */
const toolGlyph = (tool: string | null): string => TOOL_GLYPHS[(tool ?? "").toLowerCase().replace(/[_\-\s]/g, "")] ?? "⚙";

/** The sign a bare hunk string carries, for a feed that sent no `lines`. */
const signOf = (line: string): DiffLine["sign"] => (line.startsWith("+") ? "+" : line.startsWith("-") ? "-" : " ");

/**
 * An event header: the analogue of opencode's block title.
 *
 * The badge keeps its direction colour, then the human topic `label` in bright
 * text, then the `body` only when it says something the label did not — the
 * feed often sets both to the same string, and printing it twice reads as a
 * rendering fault. The age stays right-aligned and muted.
 */
const drawEventHeaderRow = (
  context: SKRSContext2D,
  row: TranscriptRow & { kind: "event_header" },
  width: number,
  baseline: number,
  now: number,
): void => {
  const right = width - PAD;
  context.font = CHAT_BADGE_FONT;
  const badgeWidth = runText(context, row.badge.toUpperCase(), PAD, baseline, badgeColour(row.badge), CHAT_BADGE_MAX);
  const age = ageLabel(row.timestamp, now);
  const ageWidth = age === null ? 0 : rightText(context, age, right, baseline, OPENCODE.textMuted) + 8;

  const labelX = PAD + badgeWidth + 8;
  context.font = `700 ${EVENT_TEXT_SIZE}px sans-serif`;
  const labelWidth = runText(context, row.label, labelX, baseline, OPENCODE.text, right - ageWidth - labelX);
  if (row.body !== row.label) {
    const bodyX = labelX + labelWidth + 8;
    context.font = CHAT_BODY_FONT;
    runText(context, row.body, bodyX, baseline, OPENCODE.textMuted, right - ageWidth - bodyX);
  }
};

/**
 * A message row, in opencode's speaker grammar, colour-coded by row class.
 *
 * Assistant prose is the case with no gutter token at all; every other role
 * takes a glyph, a fill or a bar so that "nothing in the gutter" stays a
 * reliable reading of "the agent is talking". #1960 adds the per-kind colour:
 * commands/tools green, agent prose blue, logs/system tan, the user purple —
 * the same `row_kind` the server projects, so the physical deck and the
 * emulator paint the same class with the same ink. The `row_kind`/`glyph`
 * fields come from the server; a row that carries neither derives both from
 * its role.
 */
const drawMessageRow = (context: SKRSContext2D, row: TranscriptRow & { kind: "message" }, width: number, baseline: number): void => {
  const right = width - PAD;
  const budget = right - CHAT_BODY_X;
  const kind = row.rowKind ?? rowKindOfRole(row.role);
  const colour = CHAT_COLOURS[kind];

  if (kind === "agent") {
    context.font = CHAT_BODY_FONT;
    runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
    return;
  }

  if (kind === "command") {
    if (row.role === "tool") {
      // The row shows the command or path, not the tool name: the server
      // already carried the argument in `body` (verb stripped) and the glyph
      // in `glyph`, so a tool row reads `→ lib/aiur.ex` rather than
      // `Read [path=lib/aiur.ex]`.
      context.font = CHAT_GLYPH_FONT;
      runText(context, row.glyph ?? toolGlyph(row.tool), CHAT_GLYPH_X, baseline, colour, CHAT_BODY_X - CHAT_GLYPH_X);
      context.font = CHAT_MONO_FONT;
      runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
      return;
    }
    // opencode gives bash no colour of its own: the `$` is the differentiator.
    chatRowFill(context, width, baseline, OPENCODE.backgroundPanel);
    context.font = CHAT_GLYPH_FONT;
    runText(context, "$", CHAT_GLYPH_X, baseline, colour, CHAT_BODY_X - CHAT_GLYPH_X);
    context.font = CHAT_MONO_FONT;
    runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
    return;
  }

  if (kind === "user") {
    chatRowFill(context, width, baseline, OPENCODE.backgroundPanel);
    context.fillStyle = OPENCODE.secondary;
    context.fillRect(CHAT_BAR_X, baseline - CHAT_ROW_RISE, CHAT_BAR_WIDTH, CHAT_LINE_HEIGHT);
    context.font = CHAT_BODY_FONT;
    runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
    return;
  }

  // logs: system/reasoning/alert/ci rows keep a role glyph so they are not
  // read as prose, but take the tan log colour like the emulator.
  context.font = CHAT_GLYPH_FONT;
  runText(context, ROLE_GLYPHS[row.role] ?? "·", CHAT_GLYPH_X, baseline, colour, CHAT_BODY_X - CHAT_GLYPH_X);
  context.font = CHAT_BODY_FONT;
  runText(context, row.body, CHAT_BODY_X, baseline, colour, budget);
};

/**
 * A diff row, unified — opencode only splits above 120 columns and this panel
 * is nowhere near that wide.
 *
 * ONE TranscriptRow IS ALWAYS ONE PAINTED ROW. The controller addresses
 * transcript rows by index to scroll and to jump the log keys, so a row that
 * painted three lines would move the readout three rows for one detent. The
 * *feed* therefore unrolls a hunk into a header row plus one `diff_line` row
 * each — the expansion happens where the indices are assigned, not here.
 *
 * This is the header: opencode's block title. Panel fill, a `┃` notch, the path
 * as a muted title, and the `+N -M` counts right-aligned. The counts are not an
 * opencode element (there they appear only on a revert banner) but the feed
 * carries them and they earn their space on this row — never on a row that is
 * itself a diff line.
 *
 * `line` is the fallback for a provider that gave a summary and no hunk: rather
 * than a header with nothing under it, the one line it did give rides here.
 *
 * There are no line numbers. opencode always shows them; our feed carries none,
 * and numbering the hunk's own offsets would print invented data on a
 * glanceable surface.
 */
const drawDiffRow = (context: SKRSContext2D, row: TranscriptRow & { kind: "diff" }, width: number, baseline: number): void => {
  const right = width - PAD;

  chatRowFill(context, width, baseline, OPENCODE.backgroundPanel);
  context.font = CHAT_GLYPH_FONT;
  runText(context, "┃", CHAT_GLYPH_X, baseline, OPENCODE.textMuted, CHAT_BODY_X - CHAT_GLYPH_X);

  context.font = CHAT_BADGE_FONT;
  const countsWidth = rightText(context, `+${row.additions} -${row.deletions}`, right, baseline, OPENCODE.textMuted) + 10;

  context.font = CHAT_MONO_FONT;
  const pathWidth = runText(context, row.path, CHAT_BODY_X, baseline, OPENCODE.textMuted, right - countsWidth - CHAT_BODY_X);
  const cursor = CHAT_BODY_X + pathWidth + 8;

  if (row.line !== null) {
    runText(context, row.line, cursor, baseline, DIFF_SIGN_COLOR[signOf(row.line)], right - countsWidth - cursor);
  }
};

/**
 * One line of the hunk: opencode's unified diff row.
 *
 * Full-row background fill by sign, the sign glyph in the brighter highlight
 * colour, and the line itself in the bright text colour — the three signals
 * opencode uses, at the one type size this strip has.
 */
const drawDiffLineRow = (context: SKRSContext2D, row: TranscriptRow & { kind: "diff_line" }, width: number, baseline: number): void => {
  chatRowFill(context, width, baseline, DIFF_ROW_FILL[row.sign]);
  context.font = CHAT_MONO_FONT;
  runText(context, row.sign === " " ? "·" : row.sign, CHAT_GLYPH_X, baseline, DIFF_SIGN_COLOR[row.sign], CHAT_BODY_X - CHAT_GLYPH_X);
  runText(context, row.text, CHAT_BODY_X, baseline, row.sign === " " ? OPENCODE.textMuted : OPENCODE.text, width - PAD - CHAT_BODY_X);
};

/** One transcript row as a single line of the chat readout. */
const drawChatRow = (context: SKRSContext2D, row: TranscriptRow, width: number, baseline: number, now: number): void => {
  if (row.kind === "event_header") return drawEventHeaderRow(context, row, width, baseline, now);
  if (row.kind === "diff") return drawDiffRow(context, row, width, baseline);
  if (row.kind === "diff_line") return drawDiffLineRow(context, row, width, baseline);
  return drawMessageRow(context, row, width, baseline);
};

/** A dial hint: the caption plus arrows that appear only where there is more. */
export const drawHint = (
  context: SKRSContext2D,
  label: string,
  x: number,
  baseline: number,
  hasPrevious: boolean,
  hasNext: boolean,
): void => {
  const text = `${hasPrevious ? "‹" : " "} ${label} ${hasNext ? "›" : " "}`;
  context.font = "700 9px monospace";
  context.fillStyle = hasPrevious || hasNext ? ACCENT_LIVE : LABEL;
  context.fillText(text, x, baseline);
};

/**
 * logs mode as one continuous readout of the agent's chat log.
 *
 * Five rows at the event keys' own type size, and the two dial hints on a
 * bottom line: `CHAT` under dial A, which scrolls this view, and `EVENTS` under
 * dial D, which pages the keys. The arrows are state — they show only where
 * there is something further in that direction.
 */
export const drawChatLog = (context: SKRSContext2D, width: number, content: SegmentContent & { kind: "chatLog" }, now: number): void => {
  if (content.rows.length === 0) {
    context.font = CHAT_BODY_FONT;
    context.fillStyle = OPENCODE.textMuted;
    context.fillText("No chat yet.", CHAT_BODY_X, CHAT_FIRST_BASELINE + CHAT_LINE_HEIGHT);
  }
  content.rows.forEach((row, index) => {
    drawChatRow(context, row, width, CHAT_FIRST_BASELINE + index * CHAT_LINE_HEIGHT, now);
  });
  drawHint(context, "CHAT", PAD, HEIGHT - 5, content.chatHasPrevious, content.chatHasNext);
  drawHint(context, "EVENTS", width * 0.75, HEIGHT - 5, content.eventHasPrevious, content.eventHasNext);
};

/**
 * cmd mode as one continuous readout of the focused agent.
 *
 * The left quarter is a summary column that mirrors the top of the agent's grid
 * key — epic icon, provider mark, ticket id — plus the BACK hint, which sits
 * under dial A because dial A is what performs it. The remaining three quarters
 * are one area, with no dividers: the full title, the activity, the elapsed
 * time, and a bar that runs the whole width because the progress it shows is
 * one number, not three.
 */

// Data model for the looping Aiur dashboard simulation.
// Theme: "ShopWave", a fictional e-commerce/payments SaaS.
// See elixir/docs/brainstorms/2026-05-30-aiur-terminal-simulation-handoff.md

export type Agent = "opus" | "sonnet" | "codex";
export type Phase =
  | "brainstorm"
  | "plan"
  | "implement"
  | "review"
  | "done"
  | "blocked"
  | "decide";

export interface Keyframe {
  t: number; // loop second this frame becomes active
  phase: Phase;
  progress: number; // 0..100 target at this t
  latest: string; // LATEST cell text
}

export interface TicketScript {
  id: number;
  agent: Agent;
  title: string;
  seedSec: number; // elapsed time shown at loop t=0
  frames: Keyframe[]; // ascending t; first frame is t=0
}

export type EventKind = "publish" | "receive" | "read";
export interface LogEvent {
  t: number;
  kind: EventKind;
  id: number;
  text: string;
}

export const LOOP_SECONDS = 90;
export const PROJECT = "its-everdred/shopwave";
export const ACTIVE = 10;
export const MAX = 15;

// Take-the-wheel beat (v2 staged narrative). Two separate occurrences:
// (1) a human steers #321 in an opencode pane — surfaced decision, the operator
// types a reply, the agent acknowledges; #321 does NOT resolve. Then (2) a
// separate autonomous #318 -> #319 unblock plays AFTER the pane closes.
// Milestones (loop seconds): cursor descends from descentStart, pane is open
// [open, close), the ❗ alert + A/B/C question land at alertAt, the operator
// types [typeStart, sendAt), the reply lands at replyAt, the pane closes and the
// cursor ascends to ascentEnd. The descent starts early so the loop opening is
// not dead air once #318 -> #319 moves past close.
export const BEAT = {
  decideStart: 2,
  descentStart: 3,
  open: 6,
  alertAt: 9,
  typeStart: 11,
  sendAt: 14,
  replyAt: 16,
  close: 19,
  ascentEnd: 22,
} as const;

// Fixed opencode pane height (rows). Must stay <= the dashboard's rendered
// height (NON_TICKET_ROWS 9 + VISIBLE_TICKETS 6 + WIDE_LOG_LINES 3 = 18) so the
// side-by-side join never grows the grid taller mid-loop. buildOpencodeLines
// pads to exactly this many rows with blank placeholders.
export const OC_TOTAL_ROWS = 17;

export const TICKETS: TicketScript[] = [
  {
    id: 312,
    agent: "opus",
    title: "Stripe webhook retries",
    seedSec: 378,
    frames: [
      { t: 0, phase: "implement", progress: 70, latest: "running webhook retry tests" },
      { t: 40, phase: "implement", progress: 85, latest: 'pushed 4 commits, last: "backoff"' },
      { t: 70, phase: "done", progress: 100, latest: "done — awaiting review" },
    ],
  },
  {
    id: 314,
    agent: "codex",
    title: "Checkout cart persistence",
    seedSec: 422,
    frames: [
      { t: 0, phase: "review", progress: 80, latest: "review: addressing comments" },
      { t: 25, phase: "review", progress: 90, latest: "re-running test suite" },
      { t: 45, phase: "done", progress: 100, latest: "done — awaiting review" },
    ],
  },
  {
    id: 315,
    agent: "sonnet",
    title: "Inventory decrement race",
    seedSec: 227,
    frames: [
      { t: 0, phase: "implement", progress: 40, latest: "writing failing test for race" },
      { t: 30, phase: "implement", progress: 60, latest: "adding row-level lock" },
      { t: 60, phase: "implement", progress: 75, latest: "tests green, refactoring" },
    ],
  },
  {
    id: 318,
    agent: "codex",
    title: "Google OAuth login",
    seedSec: 690,
    frames: [
      { t: 0, phase: "implement", progress: 88, latest: "finalizing OAuth callback" },
      { t: 24, phase: "implement", progress: 96, latest: 'pushed commit: "OAuth callback handler"' },
      { t: 27, phase: "done", progress: 100, latest: "auth API ready" },
    ],
  },
  {
    id: 319,
    agent: "sonnet",
    title: "Login form to auth API",
    seedSec: 125,
    frames: [
      { t: 0, phase: "blocked", progress: 0, latest: "blocked on #318 auth API" },
      { t: 26, phase: "blocked", progress: 0, latest: "← #318 pushed — pulling in" },
      { t: 31, phase: "implement", progress: 8, latest: "rebased on #318, updating plan" },
      { t: 34, phase: "implement", progress: 24, latest: "wiring login form to /auth/callback" },
      { t: 60, phase: "implement", progress: 42, latest: "rendering login button" },
    ],
  },
  {
    id: 321,
    agent: "opus",
    title: "Migrate users to UUID PKs",
    seedSec: 333,
    frames: [
      { t: 0, phase: "implement", progress: 50, latest: "running migration dry-run" },
      { t: 2, phase: "decide", progress: 60, latest: "needs a decision: backfill strategy" },
    ],
  },
  {
    id: 322,
    agent: "sonnet",
    title: "Rate-limit the public API",
    seedSec: 72,
    frames: [
      { t: 0, phase: "plan", progress: 20, latest: "planning token-bucket approach" },
      { t: 35, phase: "implement", progress: 30, latest: "implementing sliding window limiter" },
      { t: 75, phase: "implement", progress: 45, latest: "implementing sliding window limiter" },
    ],
  },
  {
    id: 324,
    agent: "codex",
    title: "Product search endpoint",
    seedSec: 48,
    frames: [
      { t: 0, phase: "blocked", progress: 0, latest: "blocked: awaiting search index schema" },
    ],
  },
  {
    id: 326,
    agent: "opus",
    title: "Email receipt templating",
    seedSec: 295,
    frames: [
      { t: 0, phase: "implement", progress: 60, latest: "rendering MJML preview" },
      { t: 30, phase: "implement", progress: 72, latest: "adding plain-text fallback" },
      { t: 58, phase: "implement", progress: 85, latest: "wiring to payment.succeeded" },
    ],
  },
  {
    id: 327,
    agent: "codex",
    title: "Dashboard analytics",
    seedSec: 21,
    frames: [
      { t: 0, phase: "brainstorm", progress: 10, latest: "brainstorming widget layout" },
      { t: 40, phase: "plan", progress: 22, latest: "planning chart components" },
      { t: 75, phase: "plan", progress: 30, latest: "planning chart components" },
    ],
  },
];

// Scripted event feed. Events with t <= 0 are seed history so the log is
// already full at load. Ambient publish/read traffic keeps the left log moving
// throughout the human steering beat (~3..22). The autonomous #318 -> #319
// unblock fires after the beat closes (push -> receive -> pull in -> update
// plan, ~24..30) as the loop's second, separate occurrence.
export const EVENTS: LogEvent[] = [
  // seed history (pre-loaded, fills the log at t=0)
  { t: -34, kind: "read", id: 322, text: "read public API rate-limit RFC" },
  { t: -28, kind: "publish", id: 326, text: "rendering MJML preview" },
  { t: -22, kind: "publish", id: 321, text: "running migration dry-run" },
  { t: -15, kind: "read", id: 327, text: "read analytics widget specs" },
  { t: -9, kind: "publish", id: 315, text: "writing failing test for race" },
  { t: -3, kind: "publish", id: 312, text: "running webhook retry tests" },
  // ambient during the human steering beat — log keeps moving in the left pane
  { t: 4, kind: "read", id: 326, text: "read payment.succeeded contract" },
  { t: 10, kind: "read", id: 322, text: "read token-bucket reference impl" },
  { t: 16, kind: "publish", id: 326, text: "adding plain-text fallback" },
  // autonomous #318 -> #319 unblock (second occurrence, after the pane closes)
  { t: 24, kind: "publish", id: 318, text: 'pushed commit: "OAuth callback handler"' },
  { t: 26, kind: "receive", id: 319, text: "← #318 pushed: OAuth callback handler" },
  { t: 28, kind: "publish", id: 319, text: "pulled in #318, rebasing onto /auth/callback" },
  { t: 30, kind: "publish", id: 319, text: "updated plan to incorporate #318 callback" },
  // ambient traffic fills the rest of the loop
  { t: 36, kind: "publish", id: 314, text: "done — awaiting review" },
  { t: 44, kind: "publish", id: 322, text: "implementing sliding window limiter" },
  { t: 52, kind: "publish", id: 327, text: "planning chart components" },
  { t: 60, kind: "publish", id: 319, text: "rendering login button" },
  { t: 70, kind: "publish", id: 312, text: "done — awaiting review" },
  { t: 78, kind: "publish", id: 315, text: "tests green, refactoring" },
  { t: 84, kind: "read", id: 324, text: "read elasticsearch mapping docs" },
];

// ---- opencode "take the wheel" session (#321) ----
// The deterministic content the opencode pane renders during the human beat.
// The static history appears whole when the pane opens; the ❗ alert + A/B/C
// question land at BEAT.alertAt; the operator types `typedText` char-by-char
// across [BEAT.typeStart, BEAT.sendAt), which then posts as a user block; the
// agent `reply` lands whole at BEAT.replyAt. #321 never resolves.
export type OcKind = "cmd" | "tool" | "prose";
export interface OcLine {
  kind: OcKind;
  text: string; // gutter glyph (cmd/tool) is added by the renderer
}
export interface OpencodeScript {
  chip: string;
  inputLabel: string;
  history: OcLine[]; // static transcript, shown whole once the pane opens
  alertText: string; // ❗ prefix added by the renderer
  question: string[]; // surfaced decision, shown whole at BEAT.alertAt
  typedText: string; // operator types this char-by-char, then it posts
  reply: string; // agent acknowledgement, shown whole at BEAT.replyAt
}

export const OPENCODE_SCRIPT: OpencodeScript = {
  chip: "Build · issue-321",
  inputLabel: "Build · issue-321 its-everdred/shopwave",
  history: [
    { kind: "prose", text: "Inspecting the users table before the UUID migration." },
    { kind: "cmd", text: "psql -c '\\d+ users'" },
    { kind: "tool", text: "users — 2.1M rows, id bigint primary key" },
    { kind: "prose", text: "Switching the PK to UUID needs an online backfill —" },
    { kind: "prose", text: "more involved than the ticket assumed." },
  ],
  alertText: "Alert sent.",
  question: [
    "How should I proceed?",
    "A Brainstorm options   B Continue anyway   C Stop & wait",
  ],
  typedText: "lets brainstorm options",
  reply: "OK. Let me get back to you with some options.",
};

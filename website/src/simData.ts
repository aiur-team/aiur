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

// Take-the-wheel beat: the window where the dashboard splits to show the
// operator driving #321 in an opencode pane. Timed around the existing t=26
// "schema migrated to uuid pks" publish so the decision (t=24) reads as its
// cause; #324's t=46 receive / t=50 unblock then play out full-width.
export const BEAT = { decideStart: 18, open: 20, decision: 24, close: 30 } as const;

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
      { t: 8, phase: "implement", progress: 96, latest: 'pushed commit: "OAuth callback handler"' },
      { t: 11, phase: "done", progress: 100, latest: "auth API ready" },
    ],
  },
  {
    id: 319,
    agent: "sonnet",
    title: "Login form to auth API",
    seedSec: 125,
    frames: [
      { t: 0, phase: "blocked", progress: 0, latest: "blocked on #318 auth API" },
      { t: 11, phase: "blocked", progress: 0, latest: "← #318 pushed — pulling in" },
      { t: 13, phase: "implement", progress: 8, latest: "rebased on #318, updating plan" },
      { t: 16, phase: "implement", progress: 24, latest: "wiring login form to /auth/callback" },
      { t: 55, phase: "implement", progress: 42, latest: "rendering login button" },
    ],
  },
  {
    id: 321,
    agent: "opus",
    title: "Migrate users to UUID PKs",
    seedSec: 333,
    frames: [
      { t: 0, phase: "implement", progress: 50, latest: "running migration dry-run" },
      { t: 18, phase: "decide", progress: 60, latest: "needs a decision: backfill strategy" },
      { t: 26, phase: "implement", progress: 60, latest: "applying online backfill in batches" },
      { t: 30, phase: "implement", progress: 95, latest: "online backfill complete" },
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
      { t: 0, phase: "blocked", progress: 0, latest: "blocked on #321 schema" },
      { t: 50, phase: "implement", progress: 5, latest: "scaffolding /search endpoint" },
      { t: 75, phase: "implement", progress: 20, latest: "wiring elasticsearch query" },
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
// already full at load. The hero handoff #318 -> #319 runs uninterrupted from
// ~8s (push -> receive -> pull in -> update plan); a secondary #321 -> #324
// unblock and ambient publish/read traffic fill the rest of the loop.
export const EVENTS: LogEvent[] = [
  // seed history (pre-loaded, fills the log at t=0)
  { t: -34, kind: "read", id: 322, text: "read public API rate-limit RFC" },
  { t: -28, kind: "publish", id: 326, text: "rendering MJML preview" },
  { t: -22, kind: "publish", id: 321, text: "running migration dry-run" },
  { t: -15, kind: "read", id: 327, text: "read analytics widget specs" },
  { t: -9, kind: "publish", id: 315, text: "writing failing test for race" },
  { t: -3, kind: "publish", id: 312, text: "running webhook retry tests" },
  // ambient before the handoff
  { t: 4, kind: "read", id: 326, text: "read payment.succeeded contract" },
  // hero handoff #318 -> #319 (uninterrupted)
  { t: 8, kind: "publish", id: 318, text: 'pushed commit: "OAuth callback handler"' },
  { t: 10, kind: "receive", id: 319, text: "← #318 pushed: OAuth callback handler" },
  { t: 12, kind: "publish", id: 319, text: "pulled in #318, rebasing onto /auth/callback" },
  { t: 14, kind: "publish", id: 319, text: "updated plan to incorporate #318 callback" },
  // ambient + secondary unblock after the handoff
  { t: 20, kind: "publish", id: 326, text: "adding plain-text fallback" },
  { t: 26, kind: "publish", id: 321, text: "schema migrated to uuid pks" },
  { t: 32, kind: "publish", id: 314, text: "done — awaiting review" },
  { t: 38, kind: "read", id: 322, text: "read token-bucket reference impl" },
  { t: 46, kind: "receive", id: 324, text: "← #321: schema ready, unblocking" },
  { t: 52, kind: "publish", id: 322, text: "implementing sliding window limiter" },
  { t: 60, kind: "publish", id: 327, text: "planning chart components" },
  { t: 70, kind: "publish", id: 312, text: "done — awaiting review" },
  { t: 78, kind: "publish", id: 315, text: "tests green, refactoring" },
  { t: 84, kind: "read", id: 324, text: "read elasticsearch mapping docs" },
];

// ---- opencode "take the wheel" session (#321) ----
// The deterministic transcript the opencode pane renders during the beat.
// Lines appear whole on the 1Hz repaint (no typewriter); times are loop
// seconds within [BEAT.open, BEAT.close). The decision lands at BEAT.decision,
// just before #321's existing t=26 "schema migrated to uuid pks" publish.
export type OcKind = "cmd" | "tool" | "prose" | "ack";
export interface OcLine {
  t: number; // loop second this transcript line first appears
  kind: OcKind;
  text: string; // glyph prefix ($, →, 👍) is added by the renderer
}
export interface OpencodeScript {
  chip: string;
  chipDoneAt: number; // loop second the chip gains "· done"
  inputLabel: string;
  decisionText: string;
  decisionAt: number; // loop second the decision text fills the input box
  lines: OcLine[]; // ascending t
}

export const OPENCODE_SCRIPT: OpencodeScript = {
  chip: "Build · issue-321",
  chipDoneAt: 28,
  inputLabel: "Build · issue-321 its-everdred/shopwave",
  decisionText: "online backfill in batches, no lock",
  decisionAt: BEAT.decision,
  lines: [
    { t: 20, kind: "cmd", text: "mix ecto.migrate --dry-run" },
    { t: 21, kind: "tool", text: "tool result" },
    { t: 22, kind: "prose", text: "Dry-run done. Backfilling 2.1M users will lock the" },
    { t: 23, kind: "prose", text: "table ~40s on prod. How should I run the backfill?" },
    { t: 25, kind: "ack", text: "switching to batched online backfill" },
    { t: 26, kind: "cmd", text: "edit priv/repo/migrations/..._add_uuid.exs" },
    { t: 27, kind: "tool", text: "tool result" },
    { t: 28, kind: "prose", text: "schema migrated to uuid pks — pushed" },
  ],
};

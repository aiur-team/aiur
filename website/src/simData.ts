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
// Milestones (loop seconds): #321 enters the decide state at decideStart so the
// ❗ shows in the list during the pre-roll; the cursor descends from
// descentStart; the pane is open [open, close); the ❗ alert + question are
// already in the log on open, then the three options post one-per-second from
// optStart; the operator types [typeStart, sendAt); the reply lands at replyAt;
// #321 flips to brainstorm; the pane closes and the cursor ascends to ascentEnd.
// The longer pre-roll lets a few more log lines scroll before the segment.
export const BEAT = {
  decideStart: 2,
  descentStart: 7,
  open: 10,
  optStart: 11,
  typeStart: 16,
  sendAt: 19,
  replyAt: 21,
  close: 25,
  ascentEnd: 28,
} as const;

// Fixed opencode pane height (rows). Must stay <= the dashboard's rendered
// height (NON_TICKET_ROWS 9 + VISIBLE_TICKETS 6 + WIDE_LOG_LINES 3 = 18) so the
// side-by-side join never grows the grid taller mid-loop. buildOpencodeLines
// bottom-anchors its transcript and pads the top with blank placeholders.
export const OC_TOTAL_ROWS = 18;

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
    title: "Add product analytics",
    seedSec: 333,
    frames: [
      { t: 0, phase: "implement", progress: 45, latest: "scaffolding analytics module" },
      { t: 2, phase: "decide", progress: 55, latest: "needs a decision: analytics library" },
      // operator picks "brainstorm" at the beat's reply → flips to brainstorm
      { t: 22, phase: "brainstorm", progress: 58, latest: "brainstorming analytics options" },
      { t: 34, phase: "brainstorm", progress: 64, latest: "researching PostHog (first-class TS types)" },
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

// Scripted event feed (ascending t; display order follows array order). Events
// with t <= 0 are seed history so the log is already full at load. Ambient
// publish/read traffic runs at a roughly doubled cadence (~2-4s apart) so the
// left log moves briskly. A few extra lines scroll during the longer pre-roll
// before the #321 segment. After the operator picks "brainstorm", #321 posts
// its own brainstorm/research events. The autonomous #318 -> #319 unblock fires
// after the pane closes (push -> receive -> pull in -> update plan) as the
// loop's second, separate occurrence.
export const EVENTS: LogEvent[] = [
  // seed history (pre-loaded, fills the log at t=0)
  { t: -40, kind: "read", id: 322, text: "read public API rate-limit RFC" },
  { t: -36, kind: "publish", id: 326, text: "rendering MJML preview" },
  { t: -32, kind: "read", id: 327, text: "read analytics widget specs" },
  { t: -28, kind: "publish", id: 321, text: "scaffolding analytics module" },
  { t: -24, kind: "read", id: 315, text: "read row-locking docs" },
  { t: -20, kind: "publish", id: 315, text: "writing failing test for race" },
  { t: -16, kind: "publish", id: 312, text: "running webhook retry tests" },
  { t: -12, kind: "read", id: 318, text: "read OAuth callback spec" },
  { t: -8, kind: "publish", id: 326, text: "adding plain-text fallback" },
  { t: -4, kind: "publish", id: 322, text: "planning token-bucket approach" },
  // pre-beat ambient — a few more lines scroll before the #321 segment
  { t: 1, kind: "read", id: 326, text: "read payment.succeeded contract" },
  { t: 3, kind: "publish", id: 312, text: "pushed 4 commits, last: backoff" },
  { t: 5, kind: "read", id: 322, text: "read token-bucket reference impl" },
  { t: 7, kind: "publish", id: 327, text: "planning chart components" },
  { t: 9, kind: "publish", id: 315, text: "adding row-level lock" },
  // ambient during the human steering beat — log keeps moving in the left pane
  { t: 12, kind: "read", id: 318, text: "read /auth/callback contract" },
  { t: 15, kind: "publish", id: 326, text: "wiring to payment.succeeded" },
  { t: 18, kind: "publish", id: 322, text: "implementing sliding window limiter" },
  { t: 21, kind: "read", id: 327, text: "read chart library comparison" },
  // #321 brainstorm/research + autonomous #318 -> #319 unblock (interleaved,
  // both after the pane closes at t=25)
  { t: 26, kind: "read", id: 321, text: "read TypeScript analytics SDK comparison" },
  { t: 27, kind: "publish", id: 318, text: 'pushed commit: "OAuth callback handler"' },
  { t: 29, kind: "receive", id: 319, text: "← #318 pushed: OAuth callback handler" },
  { t: 30, kind: "publish", id: 321, text: "brainstorming: PostHog · Plausible · Rudderstack" },
  { t: 31, kind: "publish", id: 319, text: "pulled in #318, rebasing onto /auth/callback" },
  { t: 33, kind: "publish", id: 319, text: "updated plan to incorporate #318 callback" },
  { t: 34, kind: "publish", id: 321, text: "researching PostHog — first-class TS types" },
  // ambient traffic fills the rest of the loop (denser)
  { t: 38, kind: "publish", id: 314, text: "done — awaiting review" },
  { t: 42, kind: "publish", id: 322, text: "implementing sliding window limiter" },
  { t: 46, kind: "publish", id: 327, text: "planning chart components" },
  { t: 50, kind: "publish", id: 319, text: "wiring login form to /auth/callback" },
  { t: 54, kind: "read", id: 312, text: "read flaky-retry incident notes" },
  { t: 58, kind: "publish", id: 326, text: "wiring to payment.succeeded" },
  { t: 62, kind: "publish", id: 319, text: "rendering login button" },
  { t: 66, kind: "publish", id: 315, text: "tests green, refactoring" },
  { t: 70, kind: "publish", id: 312, text: "done — awaiting review" },
  { t: 74, kind: "publish", id: 327, text: "brainstorming widget layout" },
  { t: 78, kind: "read", id: 324, text: "read elasticsearch mapping docs" },
  { t: 82, kind: "publish", id: 322, text: "implementing sliding window limiter" },
  { t: 86, kind: "publish", id: 326, text: "done — awaiting review" },
];

// ---- opencode "take the wheel" session (#321) ----
// The deterministic content the opencode pane renders during the human beat.
// The static history + the ❗ alert and the question head are already in the
// transcript when the pane opens; the three options post one-per-second from
// BEAT.optStart; the operator types `typedText` char-by-char across
// [BEAT.typeStart, BEAT.sendAt), which then posts as a user block; the agent
// `reply` lands whole at BEAT.replyAt. #321 never resolves here — the operator
// picks "brainstorm" and the agent goes off to research options.
export type OcKind = "cmd" | "tool" | "prose";
export interface OcLine {
  kind: OcKind;
  text: string; // gutter glyph (cmd/tool) is added by the renderer
}
export interface OcOption {
  label: string; // e.g. "1. Brainstorm options"
  detail: string; // one greyed sentence elaborating the choice
}
export interface OpencodeScript {
  chip: string;
  inputLabel: string;
  history: OcLine[]; // static transcript, present when the pane opens
  alertText: string; // ❗ prefix added by the renderer
  questionHead: string; // "How should I proceed?", present on open
  options: OcOption[]; // posted one-after-another from BEAT.optStart
  typedText: string; // operator types this char-by-char, then it posts
  reply: string; // agent acknowledgement, shown whole at BEAT.replyAt
}

export const OPENCODE_SCRIPT: OpencodeScript = {
  chip: "Build · issue-321",
  inputLabel: "Build · issue-321 its-everdred/shopwave",
  history: [
    { kind: "prose", text: "Adding product analytics to the checkout funnel." },
    { kind: "cmd", text: "npm install heap-analytics" },
    { kind: "tool", text: "✖ heap-analytics: no TypeScript types found" },
    { kind: "prose", text: "The SDK ships untyped CommonJS and pins an older" },
    { kind: "prose", text: "React — incompatible with our TS + Vite stack." },
  ],
  alertText: "Alert sent.",
  questionHead: "How should I proceed?",
  options: [
    { label: "1. Brainstorm options", detail: "Research popular analytics libraries with TS support." },
    { label: "2. Continue anyway", detail: "Force-install with a JS shim, accept the type gaps." },
    { label: "3. Stop & wait", detail: "Pause until you pick an analytics vendor." },
  ],
  typedText: "lets brainstorm options",
  reply: "On it — researching TS-friendly analytics options.",
};

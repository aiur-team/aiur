// Data model for the looping Aiur dashboard simulation.
// Theme: "ShopWave", a fictional e-commerce/payments SaaS.
// See elixir/docs/brainstorms/2026-05-30-aiur-terminal-simulation-handoff.md

export type Agent = "claude" | "codex";
export type Phase =
  | "brainstorm"
  | "plan"
  | "implement"
  | "review"
  | "done"
  | "blocked";

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

export const TICKETS: TicketScript[] = [
  {
    id: 312,
    agent: "claude",
    title: "Add Stripe webhook retry handling",
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
    title: "Build checkout cart persistence",
    seedSec: 422,
    frames: [
      { t: 0, phase: "review", progress: 80, latest: "review: addressing comments" },
      { t: 25, phase: "review", progress: 90, latest: "re-running test suite" },
      { t: 45, phase: "done", progress: 100, latest: "done — awaiting review" },
    ],
  },
  {
    id: 315,
    agent: "claude",
    title: "Fix inventory decrement race",
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
    title: "Add OAuth login with Google",
    seedSec: 690,
    frames: [
      { t: 0, phase: "implement", progress: 90, latest: "finalizing OAuth callback" },
      { t: 24, phase: "done", progress: 100, latest: 'pushed 4 commits, last: "OAuth callback handler"' },
      { t: 26, phase: "done", progress: 100, latest: "auth API ready" },
    ],
  },
  {
    id: 319,
    agent: "claude",
    title: "Wire login form to auth API",
    seedSec: 125,
    frames: [
      { t: 0, phase: "blocked", progress: 0, latest: "blocked on #318 auth API" },
      { t: 30, phase: "implement", progress: 5, latest: "wiring login form to /auth/callback" },
      { t: 55, phase: "implement", progress: 35, latest: "rendering login button" },
    ],
  },
  {
    id: 321,
    agent: "codex",
    title: "Migrate users table to UUID PKs",
    seedSec: 333,
    frames: [
      { t: 0, phase: "implement", progress: 50, latest: "running migration dry-run" },
      { t: 25, phase: "implement", progress: 70, latest: "backfilling uuid column" },
      { t: 40, phase: "implement", progress: 90, latest: 'pushed 2 commits, last: "backfill uuid column"' },
    ],
  },
  {
    id: 322,
    agent: "claude",
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
    title: "Add product search endpoint",
    seedSec: 48,
    frames: [
      { t: 0, phase: "blocked", progress: 0, latest: "blocked on #321 schema" },
      { t: 50, phase: "implement", progress: 5, latest: "scaffolding /search endpoint" },
      { t: 75, phase: "implement", progress: 20, latest: "wiring elasticsearch query" },
    ],
  },
  {
    id: 326,
    agent: "claude",
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
    title: "Dashboard analytics widgets",
    seedSec: 21,
    frames: [
      { t: 0, phase: "brainstorm", progress: 10, latest: "brainstorming widget layout" },
      { t: 40, phase: "plan", progress: 22, latest: "planning chart components" },
      { t: 75, phase: "plan", progress: 30, latest: "planning chart components" },
    ],
  },
];

// Scripted event feed. Hero handoff #318 -> #319, secondary #321 -> #324,
// woven through ambient publish/read traffic.
export const EVENTS: LogEvent[] = [
  { t: 6, kind: "publish", id: 326, text: "rendering MJML preview" },
  { t: 12, kind: "read", id: 322, text: "read public API rate-limit RFC" },
  { t: 20, kind: "publish", id: 318, text: "finalizing OAuth callback" },
  { t: 24, kind: "publish", id: 318, text: 'pushed 4 commits, last: "OAuth callback handler"' },
  { t: 26, kind: "publish", id: 318, text: "auth API ready" },
  { t: 30, kind: "receive", id: 319, text: "← 318: auth API ready, unblocking" },
  { t: 35, kind: "publish", id: 322, text: "implementing sliding window limiter" },
  { t: 40, kind: "publish", id: 321, text: 'pushed 2 commits, last: "backfill uuid column"' },
  { t: 41, kind: "publish", id: 321, text: "schema migrated to uuid pks" },
  { t: 45, kind: "publish", id: 314, text: "done — awaiting review" },
  { t: 50, kind: "receive", id: 324, text: "← 321: schema ready" },
  { t: 58, kind: "read", id: 326, text: "read payment.succeeded contract" },
  { t: 70, kind: "publish", id: 312, text: "done — awaiting review" },
  { t: 76, kind: "publish", id: 315, text: "tests green, refactoring" },
  { t: 82, kind: "read", id: 327, text: "read analytics widget specs" },
];

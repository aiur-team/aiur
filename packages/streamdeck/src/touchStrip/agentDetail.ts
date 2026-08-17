/**
 * cmd-mode strip view-model: one agent, read the way its grid key reads.
 *
 * The strip in cmd mode used to be four unrelated boxes — an identity, a
 * percentage, a BACK arrow and a "CONTROLLING" label — which said less about
 * the focused agent than the 120px key the operator had just pressed. This
 * model carries the whole readout instead: the ticket, its full title, how far
 * it has got, how long it has been at it, and what it is currently doing.
 *
 * ## Activity is real server state, not a guess
 *
 * `activity` comes from the daemon's `activity` field, which
 * `AiurWeb.StreamDeckGrid` derives from two existing server-side axes:
 * `Aiur.TicketActivity`'s workflow stage (brainstorm/plan/work/review, fed by
 * the agents' own `phase.*.start|end` alerts) and the orchestrator's
 * `waiting_reason` for the four waits an operator can act on. Nothing is
 * inferred client-side: an agent with no fresh stage and no actionable wait has
 * a null activity and the strip shows none, rather than assuming "working".
 *
 * The labels below are the strip's own wording. The TUI shows the same four
 * stages as 🧠/📋/🔨/🔍 (`Aiur.AgentList.Renderer.Markers`), but the deck draws
 * vector glyphs rather than emoji: emoji coverage depends on which fonts the
 * host has installed, and the strip's repaint diffing is byte identity on the
 * rendered JPEG, so a font substitution between machines would be invisible
 * here and a blank box on the device.
 */

import { progressFreshness, type ProgressFreshness } from "../keys.js";

/** Which vector glyph the painter draws for an activity. */
export type ActivityGlyph = "brainstorm" | "plan" | "work" | "review" | "waiting";

/** An activity the strip can show: a glyph plus the words for it. */
export interface AgentActivity {
  readonly glyph: ActivityGlyph;
  readonly label: string;
}

/**
 * The four waits share one clock glyph and are told apart by their label. A
 * distinct glyph per wait would need four shapes an operator has to learn,
 * where the shared clock already says the useful half — "parked, not working".
 */
const ACTIVITIES: Readonly<Record<string, AgentActivity>> = Object.freeze({
  brainstorm: { glyph: "brainstorm", label: "Brainstorming" },
  plan: { glyph: "plan", label: "Planning" },
  work: { glyph: "work", label: "Working" },
  review: { glyph: "review", label: "Reviewing" },
  waiting_ci: { glyph: "waiting", label: "Waiting on CI" },
  waiting_review: { glyph: "waiting", label: "Waiting for review" },
  waiting_human: { glyph: "waiting", label: "Waiting on operator" },
  waiting_dependency: { glyph: "waiting", label: "Waiting on dependency" },
});

/** Everything the cmd-mode panel draws for the focused agent. */
export interface AgentDetailModel {
  readonly ticketId: string;
  readonly title: string;
  /** Build Order lane selecting the epic icon. */
  readonly icon: string;
  /** Provider family selecting the vendor mark. */
  readonly vendor: string;
  readonly status: string;
  /** Progress percent 0..100, or `null` when the daemon has no reading. */
  readonly percent: number | null;
  readonly freshness: ProgressFreshness;
  /** Time spent so far ("42m", "3h 07m"), or null when the daemon sent none. */
  readonly elapsedLabel: string | null;
  readonly activity: AgentActivity | null;
}

/**
 * "42m" / "3h 07m" style elapsed time from a whole-second count.
 *
 * Minutes are zero-padded past the hour mark so the reading does not change
 * width as it ticks — the strip is diffed per repaint, and a jittering label
 * repaints the whole panel for no new information.
 */
export const elapsedLabel = (seconds: unknown): string | null => {
  if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds < 0) return null;
  const whole = Math.floor(seconds);
  if (whole < 60) return `${whole}s`;
  const minutes = Math.floor(whole / 60);
  if (minutes < 60) return `${minutes}m`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
};

/** The activity for a daemon `activity` value, or null when it sent none. */
export const agentActivity = (value: unknown): AgentActivity | null =>
  (typeof value === "string" ? ACTIVITIES[value] : undefined) ?? null;

const asString = (value: unknown, fallback: string): string => (typeof value === "string" && value !== "" ? value : fallback);

/**
 * `null` when the daemon has no reading, exactly as the key face reads it.
 *
 * This used to return `0`, so pressing an agent's grid key moved from a key
 * face showing a neutral no-reading bar to an 800px readout announcing "0%"
 * over a full-width red meter — two contradictory claims about one ticket, one
 * key press apart.
 */
const clampPercent = (value: unknown): number | null => {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.max(0, Math.min(100, value));
};

/**
 * Build the cmd-mode model from one projected grid agent. Every field falls
 * back to something printable rather than to `undefined`: the panel is 800px of
 * lit LCD either way, and a blank one reads as a crashed sidecar.
 */
export const agentDetailModel = (agent: Readonly<Record<string, unknown>>): AgentDetailModel => {
  const measured = clampPercent(agent.progress_percent);
  const freshness = progressFreshness(agent.progress_freshness, measured);

  return {
    ticketId: asString(agent.identifier, "—"),
    title: asString(agent.title, "Untitled ticket"),
    icon: asString(agent.icon, ""),
    vendor: asString(agent.vendor, "unknown"),
    status: asString(agent.bucket, "unknown"),
    percent: freshness === "unknown" ? null : measured,
    freshness,
    elapsedLabel: elapsedLabel(agent.runtime_seconds),
    activity: agentActivity(agent.activity),
  };
};

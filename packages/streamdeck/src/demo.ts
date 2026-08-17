/**
 * Synthetic fleet for exercising the deck without a live daemon.
 *
 * Enabled with `AIUR_STREAMDECK_DEMO=1`. The sidecar then skips the channel
 * entirely and feeds these fixtures to the same projection the real payload
 * drives, so every surface — key faces, the touch strip, the command and log
 * screens — renders exactly as it would in production.
 *
 * It exists because the real fleet is frequently all one colour: when every
 * agent is paused, every key is legitimately grey, which makes it impossible to
 * confirm by eye that the state colours, progress hues, blocked/unblocked tags,
 * direction badges, or the LIVE key work at all. The fixture deliberately
 * covers all five buckets, both footer shapes, several providers, prioritised
 * and blocked tickets, and every direction badge.
 *
 * Values mirror the shape of the Claude Design mock's generated data. Nothing
 * here is used unless the demo flag is set.
 */

import type { DiffLine, StreamDeckGrid, StreamDeckLogs, TranscriptRow } from "./channel.js";

/** One synthetic agent, in the daemon's grid payload shape. */
type DemoAgent = Readonly<Record<string, unknown>>;

/*
 * The first few agents carry an `activity` and a `runtime_seconds` so the
 * cmd-mode strip's activity readout and elapsed time are exercised — including
 * an agent with neither, which is what the daemon sends for a ticket with no
 * fresh workflow stage and no actionable wait.
 */
const AGENTS: readonly DemoAgent[] = [
  { identifier: "401", title: "Auth refactor and session rotation", vendor: "claude", icon: "key", bucket: "running", progress_percent: 72, progress_freshness: "fresh", priority: false, dependency_ready: true, activity: "waiting_ci", runtime_seconds: 11_240 },
  // The flicker case, held still: a real reading that has aged past the
  // freshness window. It must keep its percent and read as not-current, never
  // collapse to an empty bar that looks like 0%.
  { identifier: "333", title: "Fleet-wide retry storm", vendor: "codex", icon: "retry", bucket: "stuck", progress_percent: 34, progress_freshness: "stale", priority: true, dependency_ready: true, activity: "work", runtime_seconds: 2_700 },
  // No reading at all. Renders as flat neutral grey — the state that used to be
  // indistinguishable from "0% done".
  { identifier: "640", title: "Tutorials — draft", vendor: "claude", icon: "book", bucket: "running", progress_percent: null, progress_freshness: "unknown", priority: false, dependency_ready: true, activity: "brainstorm", runtime_seconds: 320 },
  // A genuine zero, next to the two above so the three are comparable at a
  // glance: it paints a short solid stub, because 0% is a measurement.
  { identifier: "412", title: "Restore retry statistics", vendor: "codex", icon: "database", bucket: "running", progress_percent: 0, progress_freshness: "fresh", priority: false, dependency_ready: true, activity: "review", runtime_seconds: 18_900 },
  { identifier: "540", title: "UI polish and theming", vendor: "deepseek", icon: "palette", bucket: "alert", progress_percent: 55, priority: false, dependency_ready: true, activity: "waiting_review", runtime_seconds: 47 },
  { identifier: "620", title: "Docs site integration", vendor: "claude", icon: "globe", bucket: "paused", progress_percent: 45, priority: false, dependency_ready: true },
  { identifier: "530", title: "State management rewrite", vendor: "kimi", icon: "flow", bucket: "running", progress_percent: 63, priority: false, dependency_ready: true },
  { identifier: "520", title: "Navigation shell", vendor: "codex", icon: "components", bucket: "running", progress_percent: 27, priority: false, dependency_ready: true },
  { identifier: "718", title: "Merge gate audit", vendor: "claude", icon: "shield", bucket: "alert", progress_percent: 12, priority: true, dependency_ready: true },
  { identifier: "722", title: "Webhook delivery backoff", vendor: "codex", icon: "cloud", bucket: "running", progress_percent: 84, priority: false, dependency_ready: true },
  { identifier: "731", title: "Observability pipeline", vendor: "deepseek", icon: "pipeline", bucket: "running", progress_percent: 8, priority: false, dependency_ready: true },
  { identifier: "744", title: "Crash reporter", vendor: "openrouter", icon: "bug", bucket: "stuck", progress_percent: 41, priority: false, dependency_ready: true },
  { identifier: "751", title: "Rate limit dashboard", vendor: "claude", icon: "gauge", bucket: "running", progress_percent: 99, priority: false, dependency_ready: true },
  { identifier: "760", title: "Ticket search index", vendor: "codex", icon: "eye", bucket: "paused", progress_percent: 30, priority: false, dependency_ready: true },
  { identifier: "772", title: "Editor autosave", vendor: "kimi", icon: "pencil", bucket: "running", progress_percent: 52, priority: false, dependency_ready: true },
  { identifier: "780", title: "Release notes generator", vendor: "claude", icon: "logs", bucket: "running", progress_percent: 3, priority: false, dependency_ready: true },
  { identifier: "801", title: "Schema migration for units", vendor: "codex", icon: "database", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
  { identifier: "804", title: "Provider meter reconciliation", vendor: "claude", icon: "chart", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: false },
  { identifier: "810", title: "Workspace lock contention", vendor: "deepseek", icon: "lock", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: false },
  { identifier: "815", title: "Dependency graph levelling", vendor: "codex", icon: "flow", bucket: "queued", progress_percent: 0, priority: true, dependency_ready: true },
  { identifier: "822", title: "Golden image tests", vendor: "claude", icon: "beaker", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
  { identifier: "830", title: "Repo mirror sync", vendor: "openrouter", icon: "repo", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: false },
  { identifier: "841", title: "Alerting thresholds", vendor: "codex", icon: "alert", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
  { identifier: "850", title: "Static asset pipeline", vendor: "kimi", icon: "cloud", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: false },
  { identifier: "862", title: "Audit log retention", vendor: "claude", icon: "list", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
  { identifier: "870", title: "Session replay", vendor: "deepseek", icon: "eye", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: false },
  { identifier: "881", title: "Cost attribution", vendor: "codex", icon: "chart", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
  { identifier: "890", title: "Onboarding checklist", vendor: "claude", icon: "book", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: false },
  { identifier: "902", title: "Secrets rotation", vendor: "codex", icon: "key", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
  { identifier: "911", title: "Nightly integration run", vendor: "kimi", icon: "beaker", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: false },
  { identifier: "920", title: "Build order visualiser", vendor: "deepseek", icon: "pipeline", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
  { identifier: "933", title: "Fixture server hardening", vendor: "claude", icon: "shield", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: false },
];

/** One synthetic bus event: the key face, plus the chat that followed it. */
interface DemoEvent {
  readonly badge: string;
  /** Human topic name, exactly as `AgentEventFeed.topic_label/1` produces it. */
  readonly label: string;
  /** The publisher's own summary; falls back to the label when it adds nothing. */
  readonly body: string;
  /** Minutes ago, which drives both the key's age and the header timestamp. */
  readonly minutesAgo: number;
  readonly entries: readonly TranscriptRow[];
}

const message = (role: string, body: string, tool: string | null = null): TranscriptRow => ({ kind: "message", role, body, tool });

const diffLines = (spec: readonly string[]): readonly DiffLine[] =>
  spec.map((raw) => ({
    sign: raw.startsWith("+") ? "+" : raw.startsWith("-") ? "-" : " ",
    text: raw.slice(1),
  }));

/**
 * A diff, already unrolled the way the daemon unrolls it: a header row, then
 * one row per hunk line. The fixture builds the same shape the wire carries so
 * the demo exercises the real scroll indices rather than a shape only it has.
 */
const diff = (
  path: string,
  additions: number,
  deletions: number,
  line: string | null = null,
  lines: readonly string[] = [],
): readonly TranscriptRow[] => [
  { kind: "diff", path, additions, deletions, line },
  ...diffLines(lines).map((entry): TranscriptRow => ({ kind: "diff_line", sign: entry.sign, text: entry.text })),
];

/**
 * The demo feed, **oldest event first** — the order the surface reads in.
 *
 * The first entry is the origin anchor every projection synthesises, so the
 * fixture exercises the real left edge rather than starting mid-history. Each
 * event carries the transcript that followed it, so pressing an event key jumps
 * somewhere visibly different, and the whole set covers every direction badge,
 * every transcript role the renderer styles differently, and a real multi-line
 * diff.
 */
const EVENTS: readonly DemoEvent[] = [
  {
    badge: "INFO",
    label: "Ticket opened",
    body: "Ticket opened",
    minutesAgo: 96,
    entries: [message("system", "Workspace prepared at ~/.aiur/workspaces/401.")],
  },
  {
    badge: "CONSUME",
    label: "Comment",
    body: "Please rotate sessions on privilege change too",
    minutesAgo: 83,
    entries: [
      message("user", "Please rotate sessions on privilege change too, not just on login."),
      message("assistant", "Understood — I will widen the rotation trigger to any privilege transition."),
    ],
  },
  {
    badge: "AGENT",
    label: "Phase change",
    body: "brainstorm -> plan",
    minutesAgo: 70,
    entries: [
      message("reasoning", "Two rotation points share a guard clause; the plan should collapse them first."),
      message("assistant", "Plan written to docs/plans/2026-08-15-001-auth-rotation-plan.md."),
    ],
  },
  {
    badge: "AGENT",
    label: "Progress check-in",
    body: "34% — session store rewritten",
    minutesAgo: 52,
    entries: [
      message("command", "mix test test/aiur/auth/session_test.exs"),
      message("system", "18 tests, 0 failures"),
    ],
  },
  {
    badge: "EMIT",
    label: "Branch pushed",
    body: "feat/session-rotation",
    minutesAgo: 44,
    entries: [
      message("tool", "src/lib/aiur/auth/session.ex", "edit"),
      ...diff("src/lib/aiur/auth/session.ex", 18, 4, "+  defp rotate?(change), do: change.privilege != :unchanged", [
        "   def rotate(session, change) do",
        "-    if change.kind == :login do",
        "+    if rotate?(change) do",
        "       %{session | token: mint(), rotated_at: DateTime.utc_now()}",
      ]),
      message("tool", "pattern=\"rotate?\" path=src/lib (7 matches)", "grep"),
    ],
  },
  {
    badge: "SYSTEM",
    label: "Decision requested",
    body: "Rotate refresh tokens as well?",
    minutesAgo: 36,
    entries: [message("alert", "Rotating refresh tokens logs every device out; needs an operator call.")],
  },
  {
    badge: "CONSUME",
    label: "Decision resolved",
    body: "Access tokens only",
    minutesAgo: 28,
    entries: [message("user", "Access tokens only for now. Leave refresh alone.")],
  },
  {
    badge: "EMIT",
    label: "PR opened",
    body: "PR #1904 — Rotate sessions on privilege change",
    minutesAgo: 21,
    entries: [
      message("command", "gh pr create --fill"),
      message("assistant", "Opened PR #1904 and requested review."),
    ],
  },
  {
    badge: "CONSUME",
    label: "CI failed",
    body: "credo --strict",
    minutesAgo: 14,
    entries: [
      message("ci", "Credo: 1 refactoring opportunity in session.ex:41"),
      message("command", "mix credo --strict"),
    ],
  },
  {
    badge: "AGENT",
    label: "Progress check-in",
    body: "72% — credo clean, awaiting review",
    minutesAgo: 9,
    entries: [
      ...diff("src/lib/aiur/auth/session.ex", 3, 3, "-    |> Enum.map(fn s -> rotate(s, change) end)", [
        "-    |> Enum.map(fn s -> rotate(s, change) end)",
        "+    |> Enum.map(&rotate(&1, change))",
      ]),
      message("tool", "path=src/lib/aiur/auth/session.ex offset=30 limit=20", "read"),
    ],
  },
  {
    badge: "CONSUME",
    label: "CI passed",
    body: "All checks green on the head SHA",
    minutesAgo: 3,
    entries: [message("ci", "format, credo, test — all green on 1f4c9ab.")],
  },
  {
    badge: "AGENT",
    label: "Review comment",
    body: "Requested a test for the privilege-downgrade path",
    minutesAgo: 0,
    entries: [
      message("command", "mix test test/aiur/auth/session_test.exs --only downgrade"),
      // Deliberately last, and deliberately assistant prose: this is the row the
      // demo types out, and typing is only honest for the agent's own words.
      message("assistant", "Adding a downgrade case so the guard is covered in both directions, then re-running credo and the focused test file."),
    ],
  },
];

/**
 * Grid payload: 32 agents across all five buckets, with a build order in
 * progress so the summary segment shows its bar and ETA rather than the
 * "No build order" fallback.
 */
export const demoGrid = (): StreamDeckGrid =>
  ({
    agents: [...AGENTS],
    total: AGENTS.length,
    windows: Math.ceil(AGENTS.length / 2 / 4),
    max_column_offset: Math.max(0, Math.ceil(AGENTS.length / 2) - 4),
    build: { completed: 13, total: AGENTS.length, etaSeconds: 58 * 60 },
  }) as unknown as StreamDeckGrid;

/**
 * Provider meters, deliberately uneven: a near-exhausted session next to a
 * light one, a heavy weekly next to a fresh one, and a provider reporting no
 * windows at all so the "Awaiting data" state is visible too.
 */
export const demoUsage = (now: number): Readonly<Record<string, unknown>> => {
  const meter = (provider: string, session: number, weekly: number, sessionMins: number, weeklyHours: number) => ({
    provider,
    state: "ok",
    freshness: "fresh",
    windows: {
      session: {
        used_percent: session,
        resets_at: new Date(now + sessionMins * 60_000).toISOString(),
        duration_minutes: 300,
      },
      weekly: {
        used_percent: weekly,
        resets_at: new Date(now + weeklyHours * 3_600_000).toISOString(),
        duration_minutes: 10_080,
      },
    },
  });
  return {
    claude: meter("claude", 86, 47, 22, 52),
    codex: meter("codex", 19, 78, 40, 70),
    deepseek: meter("deepseek", 55, 12, 95, 121),
    kimi: meter("kimi", 4, 63, 210, 33),
    openrouter: { provider: "openrouter", state: "unknown", freshness: "stale", windows: {} },
  };
};

/**
 * Event keys (with a LIVE row) and the flattened transcript, in the daemon's
 * log shape.
 *
 * Both sides are derived from the one {@link EVENTS} list, in the daemon's own
 * order — newest event first, each header immediately followed by its own
 * entries — so the key at slot `n` and the header the jump lands on cannot
 * drift apart in the fixture.
 */
export const demoLogs = (now: number = Date.now()): StreamDeckLogs => {
  const transcript: Record<string, unknown>[] = [];
  const starts: number[] = [];

  for (const event of EVENTS) {
    starts.push(transcript.length);
    transcript.push({
      kind: "event_header",
      badge: event.badge,
      body: event.body,
      label: event.label,
      timestamp: new Date(now - event.minutesAgo * 60_000).toISOString(),
    });
    transcript.push(...(event.entries as unknown as Record<string, unknown>[]));
  }

  return {
    // LIVE is last, not first: the surface reads oldest-left to newest-right,
    // and live is the right-hand end of a chat. Every key carries its own
    // `start`, exactly as the daemon sends it, so the fixture exercises the
    // real jump path rather than a client-side reconstruction of it.
    event_keys: [
      ...EVENTS.map((event, index) => ({
        kind: "event",
        id: `demo-${index}`,
        index,
        badge: event.badge,
        text: event.label,
        body: event.body,
        time: event.minutesAgo === 0 ? "now" : `${event.minutesAgo}m`,
        start: starts[index],
      })),
      { kind: "live", id: "live", index: EVENTS.length, label: "LIVE", start: Math.max(0, transcript.length - 1) },
    ],
    events_offset: Math.max(0, EVENTS.length + 1 - 8),
    events_max_offset: Math.max(0, EVENTS.length + 1 - 8),
    transcript,
    transcript_offset: Math.max(0, transcript.length - 1),
    transcript_max_offset: Math.max(0, transcript.length - 1),
  };
};

/**
 * Advances the fixture so the deck visibly ticks: running agents gain progress
 * and wrap at 100. A static screen cannot show that repaints are landing.
 */
export const advanceDemoGrid = (grid: StreamDeckGrid, step: number): StreamDeckGrid => ({
  ...grid,
  agents: grid.agents.map((agent) =>
    // Only a fresh, known reading advances. A stale or unknown one holds still,
    // because the point of those two fixtures is that they are *not* moving —
    // and wrapping them through zero would reproduce on purpose the exact
    // flicker this change exists to remove.
    agent.bucket === "running" && typeof agent.progress_percent === "number" && agent.progress_freshness === "fresh"
      ? { ...agent, progress_percent: Math.min(100, (agent.progress_percent as number) + step) }
      : agent,
  ),
});

/**
 * The sentence the demo types out, one flush at a time.
 *
 * Live typing is the one behaviour a static fixture cannot show, and it is also
 * the one the operator is most likely to think is broken if it silently does
 * nothing. Each call appends a further clause to the newest message, which is
 * exactly the shape a real provider flush has, so the typewriter's
 * resume-on-extension path is exercised rather than only its restart path.
 */
const TYPING_CLAUSES: readonly string[] = [
  "Adding a downgrade case",
  "Adding a downgrade case so the guard is covered in both directions,",
  "Adding a downgrade case so the guard is covered in both directions, then re-running credo",
  "Adding a downgrade case so the guard is covered in both directions, then re-running credo and the focused test file.",
];

export const advanceDemoLogs = (logs: StreamDeckLogs, tick: number): StreamDeckLogs => {
  const transcript = logs.transcript ?? [];
  if (transcript.length === 0) return logs;
  const last = transcript[transcript.length - 1];
  if (last.kind !== "message") return logs;
  const body = TYPING_CLAUSES[tick % TYPING_CLAUSES.length];
  return { ...logs, transcript: [...transcript.slice(0, -1), { ...last, body }] };
};

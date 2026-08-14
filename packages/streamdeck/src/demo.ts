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

import type { StreamDeckGrid, StreamDeckLogs, TranscriptRow } from "./channel.js";

/** One synthetic agent, in the daemon's grid payload shape. */
type DemoAgent = Readonly<Record<string, unknown>>;

const AGENTS: readonly DemoAgent[] = [
  { identifier: "401", title: "Auth refactor and session rotation", vendor: "claude", icon: "key", bucket: "running", progress_percent: 72, priority: false, dependency_ready: true },
  { identifier: "333", title: "Fleet-wide retry storm", vendor: "codex", icon: "retry", bucket: "stuck", progress_percent: 34, priority: true, dependency_ready: true },
  { identifier: "640", title: "Tutorials — draft", vendor: "claude", icon: "book", bucket: "running", progress_percent: 18, priority: false, dependency_ready: true },
  { identifier: "540", title: "UI polish and theming", vendor: "deepseek", icon: "palette", bucket: "alert", progress_percent: 55, priority: false, dependency_ready: true },
  { identifier: "412", title: "Restore retry statistics", vendor: "codex", icon: "database", bucket: "running", progress_percent: 91, priority: false, dependency_ready: true },
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

/** One synthetic event: the key face, plus the chat that event published. */
interface DemoEvent {
  readonly badge: string;
  readonly text: string;
  /** Minutes ago, which drives both the key's age and the header timestamp. */
  readonly minutesAgo: number;
  readonly entries: readonly TranscriptRow[];
}

const message = (role: string, body: string): TranscriptRow => ({ kind: "message", role, body });
const diff = (path: string, additions: number, deletions: number, line: string | null = null): TranscriptRow =>
  ({ kind: "diff", path, additions, deletions, line });

/**
 * The demo feed, newest event first.
 *
 * Each event carries the chat it published, so the fixture exercises the
 * behaviour the logs surface exists for: pressing an event key scrolls the
 * strip to that event's header and the messages that followed it. A flat list
 * of pre-rendered lines cannot show that, because there are no headers to jump
 * to. The first four events are deliberately dense, so the jump lands somewhere
 * visibly different each time.
 */
const EVENTS: readonly DemoEvent[] = [
  {
    badge: "EMIT",
    text: "Dependency cleared for #401",
    minutesAgo: 0,
    entries: [
      message("assistant", "Dependency on #388 is merged; unblocking the auth refactor."),
      message("tool", "gh pr view 388 --json state -> MERGED"),
      diff("src/lib/aiur/agent/dependencies.ex", 18, 4, "+  defp cleared?(ticket), do: ticket.blockers == []"),
    ],
  },
  {
    badge: "AGENT",
    text: "Rebased onto origin/main",
    minutesAgo: 3,
    entries: [
      message("assistant", "Rebasing before the test run so CI builds the merge ref."),
      diff("src/lib/aiur/orchestrator.ex", 6, 6, "-    Process.send_after(self(), :wake, 5_000)"),
      message("ci", "12 files changed, 340 insertions, 96 deletions"),
    ],
  },
  {
    badge: "SYSTEM",
    text: "Daemon reloaded workflow fixtures",
    minutesAgo: 9,
    entries: [
      message("system", "Workflow fixtures changed on disk; reloading the agent registry."),
      diff("src/examples/workflows/github-claude.aiurconfig", 3, 1),
    ],
  },
  {
    badge: "CONSUME",
    text: "Merge gate approved #412",
    minutesAgo: 14,
    entries: [
      message("assistant", "Human merge gate satisfied; queueing the merge."),
      message("ci", "All checks passed on the head SHA."),
    ],
  },
  { badge: "INFO", text: "Retry budget exhausted on #333", minutesAgo: 21, entries: [message("system", "Retry budget exhausted after 5 attempts; the agent is stuck.")] },
  { badge: "EMIT", text: "Opened PR #1904 for review", minutesAgo: 28, entries: [message("assistant", "Opened PR #1904 and requested review.")] },
  { badge: "AGENT", text: "Worker claimed ticket #530", minutesAgo: 36, entries: [message("assistant", "Claimed #530 and started the state management rewrite.")] },
  { badge: "SYSTEM", text: "Provider meter refreshed", minutesAgo: 44, entries: [message("system", "Claude session window is at 86%.")] },
  { badge: "INFO", text: "Workspace lock released", minutesAgo: 52, entries: [message("system", "Workspace lock for #810 released after 4m of contention.")] },
  { badge: "CONSUME", text: "Nightly run scheduled", minutesAgo: 61, entries: [message("system", "Nightly integration run scheduled for 02:00.")] },
  { badge: "SYSTEM", text: "Ticket #718 needs operator input", minutesAgo: 70, entries: [message("alert", "Merge gate audit needs a decision before it can continue.")] },
  { badge: "EMIT", text: "Branch pushed for #520", minutesAgo: 83, entries: [message("assistant", "Pushed feat/navigation-shell.")] },
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
  const transcript = EVENTS.flatMap((event) => [
    {
      kind: "event_header",
      badge: event.badge,
      body: event.text,
      timestamp: new Date(now - event.minutesAgo * 60_000).toISOString(),
    },
    ...event.entries,
  ]);
  return {
    event_keys: [
      { kind: "live", id: "live", index: 0, label: "LIVE" },
      ...EVENTS.map((event, index) => ({
        kind: "event",
        id: `demo-${index}`,
        index: index + 1,
        badge: event.badge,
        text: event.text,
        time: event.minutesAgo === 0 ? "now" : `${event.minutesAgo}m`,
      })),
    ],
    events_offset: 0,
    events_max_offset: Math.max(0, EVENTS.length + 1 - 8),
    transcript,
    transcript_offset: 0,
    transcript_max_offset: Math.max(0, transcript.length - 2),
  };
};

/**
 * Advances the fixture so the deck visibly ticks: running agents gain progress
 * and wrap at 100. A static screen cannot show that repaints are landing.
 */
export const advanceDemoGrid = (grid: StreamDeckGrid, step: number): StreamDeckGrid => ({
  ...grid,
  agents: grid.agents.map((agent) =>
    agent.bucket === "running"
      ? { ...agent, progress_percent: (((agent.progress_percent as number) + step) % 101) }
      : agent,
  ),
});

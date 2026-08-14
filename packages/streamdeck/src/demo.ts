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

import type { StreamDeckGrid, StreamDeckLogs } from "./channel.js";

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

const BADGES = ["EMIT", "CONSUME", "AGENT", "SYSTEM", "INFO"] as const;

const EVENT_TEXT: readonly string[] = [
  "Dependency cleared for #401",
  "Picked up build order barrier",
  "Daemon reloaded workflow fixtures",
  "Opened PR #1904 for review",
  "Retry budget exhausted on #333",
  "Merge gate approved #412",
  "Worker claimed ticket #530",
  "Provider meter refreshed",
  "Workspace lock released",
  "Nightly run scheduled",
  "Ticket #718 needs operator input",
  "Branch pushed for #520",
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

/** Event keys (with a LIVE row) and a transcript, in the daemon's log shape. */
export const demoLogs = (): StreamDeckLogs => ({
  event_keys: [
    { kind: "live", id: "live", index: 0, label: "LIVE" },
    ...EVENT_TEXT.map((text, index) => ({
      kind: "event",
      id: `demo-${index}`,
      index: index + 1,
      badge: BADGES[index % BADGES.length],
      text,
      time: index === 0 ? "now" : `${index * 3}m`,
    })),
  ],
  events_offset: 0,
  events_max_offset: Math.max(0, EVENT_TEXT.length + 1 - 8),
  transcript: [
    { line: "[EMIT] Dependency cleared for #401" },
    { line: "Rebasing onto origin/main" },
    { line: "Running the focused test suite" },
    { line: "12 files changed, 340 insertions" },
    { line: "[SYSTEM] Daemon reloaded workflow fixtures" },
    { line: "Waiting on the merge queue" },
    { line: "Opened PR #1904 for review" },
    { line: "CI green on the head SHA" },
  ],
  transcript_offset: 0,
  transcript_max_offset: 6,
});

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

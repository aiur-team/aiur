# Current Architecture — How Aiur Is Built Today

Companion research: `research-history-hotspots.md` (pain analysis),
`research-arch/` (duplication maps + per-giant censuses),
`feature-inventory.md` (behavior contract). Generated 2026-07-06.

---

## Runtime shape

- **Stack:** Elixir 1.19.5 / OTP 28 (pinned in `mise.toml`), Phoenix LiveView
  dashboard, SQLite via ecto/exqlite, `opencode` CLI pinned to 1.17.10. Ships
  as an OTP release (`mix build`) behind a shared shell engine:
  npm-installed `aiur` (or `scripts/aiurdev` dev shim) →
  `packaging/npm/aiur-cli/libexec/aiur-engine.sh` → release `bin/aiur`.
- **Supervision:** `Aiur.Application` (`src/lib/aiur.ex`), flat
  `:one_for_one`. Core children always run (PubSub, registries,
  ProcessReaper, AgentResourceGuard, WorkflowStore, RepoBase, the events
  stack, CodeOwners, TrackedSet, **Orchestrator**, ProgressCheckin,
  Logs.Retention, conditional HttpServer, opencode stack). Interactive-only
  children (Tmux, PaneManager, PrewarmSupervisor, AgentList.App/Input,
  LauncherWatchdog) are dropped in `--bg` headless mode. `child_specs/1` is
  deliberately pure.
- **Control plane:** shell subcommands map to hardcoded
  `Aiur.AgentControlCLI` function/arity pairs over one-shot RPC, with the
  `__AIUR_CONTROL_EXIT__:<code>` marker protocol duplicated between Elixir
  and `aiur-engine.sh` (FI-CLI section).

## Subsystem map

| Subsystem | Paths | Role | Inventory |
|---|---|---|---|
| Orchestrator + AgentRunner | `src/lib/aiur/orchestrator.ex`, `agent_runner.ex` | polling, claiming, dispatch gates, retry/reconciliation/cleanup, turn lifecycle | FI-ORC |
| Coding-agent registry + Codex | `coding_agent.ex`, `session_handle.ex`, `codex/` | backend registry, codex app-server adapter, dynamic tools | FI-CDX |
| Claude backends | `claude/` | headless (aiur-claude app-server) + claude-repl/RC, hooks, tailers | FI-CLD |
| Opencode bridge | `opencode/` (28 files) | chat-pane TUI bridge: slots, attach pool, session writers | FI-OC |
| Events + alerts | `events/`, `alerts.ex`, `alert_feed.ex` | event bus, agent APIs, GitHub pollers, alert lifecycle | FI-EVT, FI-GH |
| Trackers | `github/`, `linear/`, `memory/`, `tracker.ex` | label-lifecycle state machine + adapters | FI-GH, FI-TRK |
| TUI | `tmux.ex`, `pane_manager.ex`, `agent_list/` | panes, renderer, input | FI-TUI |
| Workspaces + init | `workspace.ex`, `init.ex`, `test_reset.ex`, `prewarm/` | per-issue workspaces, scaffold wizard, prewarm, sandbox guards | FI-WS, FI-PW |
| Web | `src/lib/aiur_web/` | LiveView dashboard, presenter, auth gate | FI-WEB |
| Engine + packaging | `scripts/`, `packaging/`, `src/Makefile`, mix tasks | launcher, control RPC, release/npm/docker pipelines, dev gates | FI-ENG |
| Skills + website | `.claude/skills/`, `.codex/skills/`, `website/` | driver/workspace/codex-native skills; marketing site + terminal sim | FI-SKL, FI-SITE |

## Backend dispatch reality (brief correction)

The seam is half-built: `coding_agent.ex` holds a single registry
(`backends/0` — codex, claude, claude-repl; per-backend `adapter`,
`transcript`, `resumable`, model/effort sets; unknown ids fail loud), and
`orchestrator.ex` contains **no** backend-literal branching. Residual inline
branching survives in `agent_runner.ex` (~638–1052: claude vs claude-repl
session reporting, remote-session promotion, spawn-failure fallback). There
is no formal `@behaviour` for adapters. The two app-server adapters
(`codex/coding_agent.ex`, `claude/coding_agent.ex`) are structural twins
(~60–70% shared shape — see `research-arch/dup-backends.md`).

## The giants (files > 1,000 lines, re-measured 2026-07-06)

`orchestrator.ex` 7,617 · `github/client.ex` 2,597 · `init.ex` 2,253 ·
`agent_runner.ex` 2,215 · `agent_list/renderer.ex` 2,139 ·
`codex/coding_agent.ex` 1,997 · `pane_manager.ex` 1,839 ·
`agent_list/app.ex` 1,587 · `opencode/slot.ex` 1,392 · `workspace.ex` 1,235 ·
`claude/repl_agent.ex` 1,175 · `opencode/chat_completions.ex` 1,127 ·
`codex/dynamic_tool.ex` 1,073 · `config/schema.ex` 1,017 · `tmux.ex` 1,005.
Per-file function censuses and proposed splits: `research-arch/giant-*.md`.

## Duplication map

27 confirmed clusters across two reports (paths, shapes, and consolidation
proposals in `research-arch/dup-backends.md` and `dup-infra.md`). Headlines:

- **App-server adapter twins:** codex and claude headless adapters duplicate
  the JSON-RPC port core (framing, handshake, RPC ids, turn-loop
  control-message vocabulary — pause/queue-update appears in four receive
  loops), usage/token normalization (3.5 copies), and transcript scaffolding.
- **Poller skeletons:** periodic-tick GenServer shape, GitHub connectivity
  streak/backoff/alert fold, and sanitize-then-publish pipeline are
  re-implemented per poller.
- **Cross-language mirrors:** the reap stack and the control-RPC marker
  constants exist twice (shell engine + BEAM); project-root/config discovery
  exists in two languages; two tmux conf copies have live drift.
- **Utility sprawl:** `shell_escape` ×6 (two dialects), identifier/filesystem
  sanitization regex ×5 (a cross-subsystem join key), `$VAR` env resolution
  double-implemented (Schema vs `Linear.Config`), codex approval-policy
  validator and default sandbox-policy map each duplicated, atomic
  write-then-rename repeated, JSONL decode-or-skip wrappers repeated.
- **Latent code:** `Aiur.Claude.EventHumanizer` has no caller (FI-CLD-025);
  event-humanizer pair lacks backend dispatch.

## Test & CI reality

- 173 test files / ~2,315 tests; `src/test/aiur/regression/` holds 19
  characterization-style tests; ANSI snapshot support exists.
- **The coverage trap that becomes our ratchet:** `src/mix.exs` exempts the
  giants from the 85% threshold via `ignore_modules` — the riskiest modules
  are the least covered, but modules *extracted* from them are not exempt.
- CI (`.github/workflows/ci.yml`): build, fmt-check + lint
  (`specs.check` + `credo --strict`), coverage + regression, dialyzer — all
  from `src/`. `pull_request` trigger is unfiltered (PRs to any base run CI);
  `push` CI is main-only. **`website/` has no CI at all**; its guards
  (typecheck, golden-snapshot `assert`, build) are manual conventions.
- Known flake mechanics and the never-prune whitelist are codified in
  `regression-safety.md`.

## Pain analysis

Full ranked map with evidence: `research-history-hotspots.md` (551 classified
incidents from 248 PRs + 281 issues + the fix-plan wave). Top hotspots: the
GitHub comment→wake/rework pipeline (~35 incidents, the repo's longest
fix-of-fix chains), test isolation (~24), launcher/instance identity (~21),
workspace lifecycle (~19), opencode slots/attach (~17), orchestrator dispatch
(~15). Recurring themes that shape ticket design: send-then-assume timing
races, stale disk state outliving its owner, label races on the tracker state
machine, reap-scoping oscillation, global mutable state, identity/port
collisions, resource fan-out at concurrency, shipped-but-inert fixes,
render-state threading desync, and guard/optimization regressions ("every new
skip/cutoff/cap clipped a legitimate case on first ship").

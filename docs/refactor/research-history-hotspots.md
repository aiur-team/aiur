# Research: Regression Hotspot Map from Repo History

Input research for the production-readiness refactor plan (see `docs/refactor/fable-planning-prompt.md` and `docs/plans/2026-07-06-001-refactor-production-readiness-planning-spike-plan.md`, unit U2). Purpose: tell the refactor where regressions actually happen, so characterization tests and refactor caution are spent where history says they pay off. Generated 2026-07-06.

## Method

Sources classified into JSON batches and synthesized here:

- **248 merged PRs** (#24–#723), each classified with type (`bugfix` / `regression-fix` / `flake-fix` / `feature` / `refactor` / `docs` / `infra`), subsystems, top paths, theme, and an explicit `refixes` field when a PR reworks or repairs a prior fix.
- **281 issues** (#1–#730), classified with type (`bug` / `regression` / `flake` / `enhancement` / `task`), subsystem, theme, and recurrence links.
- **22 fix-plan / measurement docs** from the 2026-06-24 fix wave (`docs/plans/`), which independently flag FIX-OF-FIX chains and root-cause classes.

**Counting rule:** an *incident* is a distinct defect (bug, regression, or flake). Issue↔PR pairs for the same defect are deduped; each link in a fix-of-a-fix chain counts as its own incident (the follow-up defect is real). Each incident is assigned to one dominant subsystem, so rows do not double-count, but boundaries involve judgment (e.g. the EPIPE family is counted under agent backends, not orchestrator). Sandbox test tickets, throwaway routing tickets, and pure feature/docs/infra work are excluded from counts.

## Ranked hotspot map

| # | Subsystem / paths | Incidents | Dominant themes |
|---|---|---:|---|
| 1 | **GitHub event ingestion & comment→wake/rework pipeline** — `src/lib/aiur/events/` (`github_firehose.ex`, `github_comments_poller.ex`, `ls_remote_ticker.ex`), `src/lib/aiur/github/client.ex`, orchestrator comment paths | ~35 | Comment-wake chain of 5+ consecutive fixes; dedup/cutoff filters hiding legit events; trust gates (CODEOWNERS) silently dead; rate-limit pressure; every polling optimization shipped a regression |
| 2 | **Test isolation & CI flakes** — `src/test/`, `src/test/support/` | ~24 | Global mutable state (env vars, config cache, named ETS, singleton Orchestrator) leaking across tests; sleep/timeout assertions failing under load; sandbox-dependent `pgrep` vacuous passes |
| 3 | **Launcher engine / instance identity / control plane** — `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `scripts/aiurdev`, `src/lib/aiur/agent_control_cli.ex` | ~21 | Instance-identity collision chain (#431→#443→#592); reaper friendly-fire on sibling/live instances; silent control-RPC failures and hangs; startup failures exiting 0 |
| 4 | **Workspace lifecycle, git metadata & prewarm base** — `src/lib/aiur/workspace.ex`, `repo_base.ex`, `agent_environment.ex`, `.aiur/hooks` | ~19 | Read-only/locked `.git` regressed 4+ times; stale-workspace refresh chain (5 fixes) incl. a load-42 host melt; stale warm base; mise trust-path class fixed twice |
| 5 | **Opencode integration (slots, attach pool, bridge, SessionWriter)** — `src/lib/aiur/opencode/` | ~17 | Warm-marker/attach races under multi-agent load; `:emfile` FD fan-out; version-pin churn (blank panes); bridge-port collisions; operator messages lost in panes (#332 recurred after 3 fixes) |
| 6 | **Orchestrator dispatch, lifecycle & retry budgets** — `src/lib/aiur/orchestrator.ex` | ~15 | Retry budget burned by non-failures (slots, tracker 403s, hooks, quota); safety nets that regressed (max-duration bound #420) or shipped disabled (load gate #477); pause/resume races |
| 7 | **Init & config scaffolding** — `src/lib/aiur/init.ex`, `config/schema.ex`, `.aiur/` layout | ~14 | Fresh-install scaffold gaps (no task, no clone hook, wrong backend deps); config-format churn (#238→#244→#333); `.aiur/` layout move broke compile-time paths, skills, alerts; init clobbers real configs (#649, #724) |
| 8 | **Agent backends: Claude/RC + Codex transport & tool parity** — `src/lib/aiur/claude/`, `src/lib/aiur/codex/` | ~14 | Coordination-tool provisioning gap re-observed 4× (#266→#515→#689/#690→#728); RC prompt-delivery races (#373 paste, #332); EPIPE crash family (#699/#708/#727); quota/cold-start misclassification |
| 9 | **Agent sandbox isolation (agent runs vs operator state)** — `src/lib/aiur/test_reset.ex`, `scripts/aiurdev`, launcher guards | ~10 | Three-plan fix-of-fix chain (001 sandbox → 008 fail-closed → 009 stale-agent refresh); agent `--test` runs mutated operator state, labels on live tickets, logs into production roots |
| 10 | **CI quality-gate baseline (lint/format drift)** — repo-wide, `.github/` | ~9 | Recurring red-main clusters (#104/#109/#125/#129, #328/#331); rename/layout fallout (#25, #282); fixes breaking lint on main (#390, #582) |
| 11 | **TUI agent-list renderer & input** — `src/lib/aiur/agent_list/` | ~8 | Render-state not threaded into layout (`Map.take` pipeline class: #414/#473); renderer desync from correct backend lifecycle (#425/#428); input escape-sequence drops (#375/#398) |
| 12 | **Process reaping & shutdown** — `src/lib/aiur/shutdown.ex`, `process_reaper.ex`, `claude/remote_control.ex` | ~7 | Orphaned process trees survive stop/crash (#380→#453→#468→#553); reap scoping repeatedly wrong (too narrow, then too broad) |
| 13 | **tmux pane management** — `src/lib/aiur/pane_manager.ex`, `tmux.ex` | ~6 | Slot-cycling fixed 3× before root cause (rogue `after-split-window` hook, #34→#51→#61→#77); stale layout state; portability (BSD `sleep`) |
| 14 | **Skills / operator monitoring tooling** — `.claude/skills/` | ~6 | Every layout change broke a skill script (#397, #434, #489/#518, #514); monitor-cadence prompt rules needed 3 passes (#596→#598→#600) |
| 15 | **Alerts** — `src/lib/aiur/alerts.ex`, `.aiur/alerts.yaml` | ~5 | Runtime-vs-compile-time path assumptions (#43 `Mix.env`, #702 stale bundled path → 15 CI failures); test runs ringing the operator's machine (#583) |

## Notable fix-of-a-fix chains

The strongest predictor of the next regression is a previous fix in the same seam. The densest chains, with evidence:

### Comment→wake/rework pipeline (longest chain, 5+ links in ~2 weeks)
- PR #621 (wake idle agents on trusted comments) → PR #623 (missed idle human-review tickets, #622) → PR #629 (comments only delivered at turn boundaries, #628) → PR #630 (woken agent never received the triggering comment) → PR #632 (transient GitHub 502 consumed the wake event, #631).
- Digest/review-thread side: PR #634 (stale-digest cutoff) → PR #642 (**regression**: cutoff hid unresolved review threads forever) → PR #677 (resolve tooling; removed #642's brittle suppression) → PR #682 (TOCTOU: reviewer comment landing mid-resolve suppressed, #679) → PR #683 (GraphQL `RATE_LIMITED` misclassified as rework trigger, #674).
- Polling-optimization regressions: PR #668 (bounded polling) → PR #672 (task exits/hangs not isolated, #671) → PR #675 (**regression** #673: `updated_at` skip missed PR comments) → PR #684 (redundant PR fetches, #676).
- Reactivation gates: #379 (PR #405, fighting #192's deactivated-agent filter) → #407 → PR #512 (counter-guard so #511's wake path can't resurrect parked tickets).
- Token/auth: PR #559 (preflight) → PR #579 (keyring fallback, #578) → PR #582 (**regression**: cached nil token broke ~73 tests on main).

### Instance identity & control plane
- #431 "instances reap each other" (PR #439, per-cwd identity) → #443 global-config key collision (PR #591) → #592 control commands from other cwd silently no-op (PR #601). Collateral: #442 dashboard port collision (PR #587), #495 stop kills sibling releases (locked in by PR #520), #498 `mix test` reaped the live aiur BEAM.

### Shutdown/reap
- #380 orphaned opencode-serve → PR #458 cwd-scoped reap (#453 whole tree survives) → #468 straggler under load → PR #501 synchronous retry + launcher backstop → PR #574 stale manual-smoke leftovers (#553).

### Workspace refresh & git metadata
- Stale-workspace chain: PR #569 (stop stale agents; before_run refresh) → #573/PR #577 (refresh gave up on dirty leftovers) → #586/PR #595 (leftover-workspace thrash, host load 42) → #653/PR #656 (**regression**: every merge killed in-flight WIP agents) → #657/PR #661 (hook failure burned retry budget).
- Git metadata: #493 → #526/PR #542 → #561 (regression) → PR #565 (stale lock repair) → #616 (regressed again, explicitly citing all three priors).
- mise trust class: #432/PR #441 (prewarm base) then #440/PR #474 (same class, agent workspaces).

### Opencode warm pool & provisioning
- Warm markers: PR #65 (opencode panes) → PR #74 (gate Enter on warm) → PR #83 (SQLite replay races + warm-marker state broken under 5-agent load) → PR #96 (architecture rework, 50s→12s boot).
- Provisioning: PR #346 (postinstall) → PR #363 (pin 1.15.6, blank panes) → PR #381 (offline/bun/pnpm/yarn hardening) → PR #606 (unpin to 1.17.10, #364).
- Slot display: #372 → PR #607 → #608 (TOCTOU/churn follow-up). FD structural: #409 measurement → PR #457 (`:emfile` fan-out cap).

### tmux pane slot cycling (classic miss-the-root-cause chain)
- #34 → PR #51 (Elixir-only fix, didn't work) → PR #61 (root cause: rogue tmux `after-split-window` hook) → PR #77 (third consecutive pane-slot PR; stale PaneManager state, #64).

### Sandbox isolation (plan-wave documented)
- Plan 001 (#482, sandbox agent IR runs) → Plan 008 (**reversal to fail-closed**: sandbox still leaked, agents relabeled live tickets) → Plan 009 (stale pre-fix agents kept running unsafe flows; stop on main push). Fallout fixed separately: #540/PR #568 (IdGenerator crash-loop on unwritable log root), PR #546 (theme setup lied in sandbox), PR #706 (`AIUR_LOGS_ROOT` leak).

### Orchestrator safety nets
- Load: #465/PR #471 (gate) → #477/PR #502 (**shipped disabled**, defaulted on) → #479/PR #503 (gate can't bound a running agent; resource guard).
- Retry budget: #549/PR #557 → #551/PR #558 (same-day, second leak path) → #699/PR #714 + PR #723 (EPIPE + claim never released).
- Max duration: #341/PR #416 (kill→pause) → #420/PR #599 (pause removed the hard bound; wedged agents unbounded).

### Flake whack-a-mole (same test, multiple mechanisms)
- `log_file_test:263`: PR #444 (stale config cache) → PR #463 (second mechanism: BEAM-wide `AIUR_DEBUG` leak, #446).
- `core_test` / CI cascade: PR #444 → PR #597 (#589 app-shutdown cascade) → PR #603 (#447 remaining timing window) → #681/PR #685 (named-ETS ownership race, "root of the recurring flakes").

### Layout/rename fallout (mechanical change, distributed breakage)
- Symphony→Aiur rename: PR #25, PR #27. `.aiur/` consolidation: PR #392 → PR #393 (compile-time `@external_resource` paths) → PR #394 (4,063 accidental build artifacts) → PR #397 (skill broken). Later: #702/PR #700 (alerts path, 15 CI failures), #434 (status skill blind), #282 (CI workflow path), #726 (PromptBuilder `__DIR__` path in relocated releases).

## Recurring cross-subsystem themes

### 1. Timing and submission races
Async seams repeatedly shipped with a race: RC paste-vs-Enter (#373/PR #374), SessionWriter replay under load (PR #83), queued-operator-message drain (#552 + Mode-B refix in plan wave), review-thread resolve TOCTOU (#679/PR #682), codex handshake port-close (PR #389), TrackedSet ETS ownership (#681/PR #685). Anything that "sends then assumes" needs an explicit ack/synchronization point.

### 2. Stale state on disk
Disk state outliving its owner caused whole incident families: stale workspaces (#573, #586), stale warm base (#567/PR #571), stale session handles (#610/PR #701), stale tokens in `.env` (#578), stale tmux sessions/sockets (#431, #483), subscription files across test runs, `/tmp` debris filling tmpfs (#334), committed build cruft (PR #394). Every persisted artifact needs an owner, a validity check, and a reaper.

### 3. Label/lifecycle races on the tracker
GitHub labels are the orchestration state machine, and they race: merged-PR vs rework comment (#560/PR #564), test reset labeling closed tickets (#535/PR #547), deactivated-agent wake gates (#379, #407, PR #512), human-review promote (#693/#696). State transitions need revalidation-at-use, not trust-at-read.

### 4. tmux & process lifecycle orphaning
Rogue tmux hook (#34 chain), orphaned process trees after stop/crash (#380→#453→#468→#553), reaper friendly-fire on siblings and live runs (#431, #495, #498). Reap scoping oscillated between too narrow (misses reparented children) and too broad (kills siblings) — the identity chain in row 3 is the same defect from the other side.

### 5. Global mutable state & env leakage
Biggest flake source and an agent-runtime bug source: env inherited into fixtures/workspaces (`$TMUX`, `ERL_AFLAGS`, `AIUR_*`, `$HOME`; #44/#45), BEAM-wide env mutation across async tests (#446), config caches (#444, #582), singleton Orchestrator/log pollution (#585), `AIUR_LOGS_ROOT` leaking production paths into agents (PR #706).

### 6. Identity and port collisions
Node names, tmux sessions, bridge port 4097 (#521/PR #536), dashboard port 4000 (#442/PR #587), instance keys (#443, #592). Any global default identity/port eventually collided; per-instance derivation plus loud failure was the repeated end state.

### 7. Resource exhaustion at concurrency
The 16-agent prewarm run (measurement doc) is the archetype: N×M attach fan-out → `:emfile` → cascade (#409/PR #457); before_run thrash at load 42 (#586); wave-start thundering herd (#692/PR #703); one agent's synthetic load starving siblings (#479/PR #503); daemon polling exhausting the 5000/hr token budget (#678). Costs that scale with agents×slots×pollers must be budgeted structurally, not tuned.

### 8. Shipped-but-inert fixes
Fixes that existed but did nothing until a follow-up: load gate default-off (#477), `Connectivity.backoff_ms` implemented but never wired into pollers (#655/PR #659), `SessionHandle.clear` never wired (#610), dashboard never bound so RC crash-looped (PR #367). A fix isn't done until something exercises it by default.

### 9. Renderer/backend state desync
The TUI renderer repeatedly lagged correct backend state because new fields must be threaded through the render-state `Map.take`/`Map.put` pipeline (#414/PR #473, #425/PR #428, #730). Mechanical seam; ideal for a characterization test that diffs backend state keys against rendered layout keys.

### 10. Guard/optimization regressions
Nearly every filter, cutoff, cap, or guard clipped a legitimate case on first ship: workpad cutoff hid unresolved reviews (PR #634→#642), bounded polling skipped PR comments (PR #668→#673), dirty-refresh guard killed WIP agents on merge (PR #569→#653), deactivated-agent event filter blocked reactivation (PR #192→#379). Treat any new "skip/ignore/cap" as high regression risk and enumerate what it must *not* skip.

## Densest characterization coverage recommended

Before refactoring, lock in current behavior with characterization tests here, in priority order:

1. `src/lib/aiur/orchestrator.ex` — comment wake/rework transitions, dispatch gates (load, slots, claims), retry-budget accounting, max-duration bounds, pause/resume/drain semantics.
2. `src/lib/aiur/events/github_comments_poller.ex`, `github_firehose.ex`, `ls_remote_ticker.ex`, `github_keys.ex` — dedup keys, boot cutoffs, workpad filtering, per-target isolation, backoff wiring.
3. `src/lib/aiur/github/client.ex` — `active_states` honoring, review-thread reply/resolve/verify flows, error taxonomy (transient vs terminal), token resolution order.
4. `packaging/npm/aiur-cli/libexec/aiur-engine.sh` — instance-identity keying, control-RPC marker protocol, stop/reap scoping, stale-session preflight, exit codes. (Shell; regression-test via `aiur_engine_test.exs` and `launcher.test.mjs` patterns already in-tree.)
5. `src/lib/aiur/workspace.ex` + `repo_base.ex` + hooks contract — refresh/recreate decision table (clean/dirty/WIP/stale), git-metadata writability invariant, prewarm materialize fallbacks.
6. `src/lib/aiur/opencode/` (`slot_policy.ex`, `attach_pool.ex`, `slot.ex`, `session_writer.ex`, `chat_completions.ex`, `bridge_port.ex`) — warm-marker lifecycle, attach/reclaim under churn, FD-budget invariants, operator-message preservation.
7. `src/lib/aiur/agent_runner.ex` — queued-message drain outcomes (never converts success to failure), events-digest filtering, session-resume handle lifecycle including terminal-state clearing.
8. `src/lib/aiur/shutdown.ex` + `process_reaper.ex` + `claude/remote_control.ex` reap paths — scope (never siblings, always own tree), synchronous completion before halt.
9. `src/lib/aiur/test_reset.ex` + `scripts/aiurdev` sandbox guards — fail-closed behavior for agent-context `--test`/reset; closed-ticket label hygiene.
10. `src/lib/aiur/agent_list/renderer.ex` + `app.ex` — render-state key threading (backend field ⇒ layout map), terminal-state rendering (flag/progress/pause).
11. `src/lib/aiur/init.ex` + `config/schema.ex` — never-clobber existing config/env, resume backfill, `.aiur/` layout resolution incl. release-relocated paths.
12. `src/lib/aiur/alerts.ex` — bundled-definition path resolution at runtime, test-env suppression.

A cheap global guard worth adding alongside: a test that greps for compile-time file-path embedding (`@external_resource`, `__DIR__`-relative reads) of files that live under `.aiur/` or move with layout — that single class produced #393, #700/#702, and #726.

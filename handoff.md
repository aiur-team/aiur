# HANDOFF — repo-agnostic eager prewarm: BUILT, awaiting Mac verification

_Last updated: 2026-06-22. Branch `feat/prewarm-base`. Full local gate green (fmt + credo --strict +
tests + 85.44% coverage + dialyzer)._

## TL;DR for the verification agent

The repo-agnostic eager **prewarm** feature is fully implemented on **`feat/prewarm-base`** (12 commits,
9 implementation units, all tested, `make -C src all` green on Linux). It builds **one shared,
pre-compiled base of latest `main` once** and materializes each agent workspace from it via
copy-on-write, instead of every agent cold-cloning + recompiling. Your job is to **pull this branch on
the MacBook (APFS = true copy-on-write) and verify it works at real scale** against aiur itself, then
**collect the findings** the implementing session needs to make a final optimization pass before merge.

Design of record: `docs/brainstorms/2026-06-22-prewarm-design-research-and-questions.md`.
Plan: `docs/plans/2026-06-22-001-feat-repo-agnostic-prewarm-plan.md`.

## What was built (the 9 units)

- **U1** `prewarm` config block (`enabled`, `base_build`, `poll_seconds`) + accessors.
- **U2** `Aiur.RepoBase` GenServer — one warm base at `~/.aiur/repo/<owner>/<name>`, clone-once,
  fetch+reset-when-main-moved, **async builds**, **PubSub phase events** (cloning→fetching→building→
  ready), and **preemption**: a newer `main` (detected via `git ls-remote`) kills an in-flight stale
  build and restarts.
- **U3** `Aiur.Prewarm.Detect` — lockfile/manifest detection (Elixir/Node/Go/Rust/Python) with a
  **build-root walk** (aiur's `mix.exs` is in `src/` behind a decoy root `package.json` — verified it
  resolves to `src/`), everything routed through `mise exec --`. nx/turbo monorepos + ambiguity → fall
  back to an agent prompt.
- **U4** `aiur init` final-step opt-in: detect → **show the command for confirm/edit/skip** → write the
  `prewarm` block; agent-prompt fallback on a miss.
- **U5** Eager **async** dispatch gate in `orchestrator.ex` (`dispatch_or_hold`/`prewarm_gate`): holds
  `choose_issues` until the base is `:ready`, **never blocks the orchestrator process**, falls back to
  cold dispatch on a base-build error.
- **U6** aiur-owned materialization in `workspace.ex` (`materialize_from_base`): `cp --reflink=auto -a`
  (Linux) / `cp -c` (macOS) from the base + branch `aiur/<id>`, **skipping** the cold after_create hook;
  cold-clone path preserved byte-for-byte for unconfigured/remote/undetected/copy-fail.
- **U7** Agent-list loading bar: spinner + live phase label before agents populate, resumes at the live
  phase on launch-mid-build, clears once the list populates.
- **U8** `--debug` FD safety: **decoupled `aiur_screen_grab` from `--debug`** (now its own
  `AIUR_SCREEN_GRAB` flag, default off), cached the tmux exe path, and **raised `ulimit -n`** in
  `aiur-engine.sh` (covers `aiur` and `aiurdev`).
- **U9** Dogfood: aiur's own `.aiur/config` has `prewarm.enabled: true` with an Elixir base_build that
  scopes `HEX_HOME`/`MIX_HOME` so the warm caches copy into workspaces.

## Your job (run on the MacBook, APFS)

1. `git fetch && git checkout feat/prewarm-base` on the Mac. Build the release (`aiurdev` rebuilds).
2. Run aiur against **aiur itself** with the full set of current `agent:todo` tickets (the dogfood
   config already has `prewarm.enabled: true`). Use **`--debug`** — it must now be safe at this scale.
3. Drive **`/aiur-status`** (the operator monitor) to watch agents and surface findings/crashes.
4. On the **first run** the base builds once (clone aiur → `~/.aiur/repo/its-everdred/aiur` → compile,
   a few minutes) while the agent list shows the **loading bar**; agents dispatch once it's `:ready`.
   Subsequent runs should find the base warm (fast) and agents should materialize in **seconds**.

## What we're looking for (success criteria + risk watch-list)

- **Warm vs cold timing**: boot → first agent message should drop from minutes to seconds once the base
  is warm. Capture the numbers.
- **No `:emfile` / no crash** at ~6+ concurrent agents **with `--debug` on** (the whole point of U8).
- **Detection correctness**: the init flow / dogfood base_build builds `src/` (Elixir), not Node off the
  root `package.json`.
- **Materialization actually fired**: workspaces should have a populated `.git` + warm `_build`/deps and
  be on branch `aiur/<id>`, and the cold after_create clone should be SKIPPED (look for the absence of a
  fresh `git clone` in `after_create`). **macOS `cp -c` is untested on Linux — this run is its first
  real exercise.** If `cp -c` errors (non-APFS path), it should fall back to cold clone, not hang.
- **Loading bar**: shows phases; a launch *during* a build resumes at the live phase (not from scratch).
- **Preemption**: if `main` advances mid-build (e.g. an agent merges), the stale base build should be
  killed and restarted — agents must never spin off a stale base. (Hard to force; note if you see it.)
- **Mix `_build` relocation**: the copied `_build` must work in the workspace (the `before_run` hook's
  incremental `mix compile` is the safety net). Watch the first agent's `mix` calls — fast, not a full
  recompile.

## Context to collect back (for the pre-merge optimization pass)

Write a throttled re-measurement into **`docs/measurements/`** with: per-phase timings (clone→fetch→
build→ready, then per-agent boot→first-message), cold-vs-warm comparison, the steady-state **tmux fork
rate** and **open-FD census** (`ls /proc/<beam-pid>/fd | wc -l` on Linux; `lsof -p <pid> | wc -l` on
Mac), any crashes/`:emfile`, and any new aiur issues you file. Flag anything that wants a final
optimization before merge.

## How to run

- Tests: `cd src && mise exec -- mix test [path]`. Full gate: `make -C src MIX='mise exec -- mix' all`.
- Run (operator): `aiurdev --debug` (now FD-safe). `/aiur-status` to monitor.
- Disable prewarm if needed: set `prewarm.enabled: false` in `.aiur/config`.
- Pane snapshots in logs (old `--debug` behavior): now opt-in via `AIUR_SCREEN_GRAB=1`.

## Gotchas / known limitations

- **Eager-gate poll latency**: when the base becomes ready, the next dispatch waits up to one poll
  interval (`polling.interval_seconds`, dogfood = 5s). No subscribe-to-`:ready` nudge in v1 — fine for a
  multi-minute build; lower `interval_seconds` if it feels laggy.
- **Local dispatch only**: remote/SSH workers always use the cold-clone path (no base on the remote host).
- **The base_build in aiur's `.aiur/config` is aiur-specific** (mix, `src/` root, scoped HEX/MIX homes).
  For a generic repo, `aiur init` detects a generic command.
- **`:emfile` structural fixes are deferred to [#409](https://github.com/its-everdred/aiur/issues/409)**
  (after merge): opencode-serve pooling, attach N×M fan-out cap, event-driven pane-death,
  capture-pane→pipe-pane, per-identifier SessionWriter subscription. This PR ships only the cheap
  fork-reducers + the `ulimit` net + the compile-storm collapse (which removes the dominant FD holder).

## Do not

- Merge without operator go-ahead. Open PRs / push are fine; merge is operator-only.
- Treat a single flaky `pane_manager_live_test`/`debug_events_ticker` red as real — re-run.

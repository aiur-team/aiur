# HANDOFF — prewarm design (measurement done; now brainstorm → plan → build)

_Last updated: 2026-06-22. Main is green._

> Note: tracked as `handoff.md` (lowercase) — on case-insensitive macOS `HANDOFF.md`
> resolves to the same file. Edit this one.

## TL;DR for the next session

The `.aiur/` migration is fully shipped. **Prewarm measurement is DONE** — a real 16-agent
run was instrumented and crashed; findings are in
**`docs/measurements/2026-06-22-prewarm-run-findings.md`** (read this first). Three
bottlenecks were quantified. The work now is to **design and build the prewarm**, via a full
compound-engineering loop (brainstorm → plan → deepen → work → code review). A brainstorm is
**in-flight** — the operator's product direction is captured below under "Prewarm direction."

## The measurement run (what we learned)

One run with `max_concurrent_agents: 20`, `pre_warmed_sessions: 5`, `kind: claude`,
`max_turns: none`, 16 `agent:todo` tickets. It **crashed at ~4.5 min with zero productive
agent turns**. Three compounding findings (full evidence + timeline in the measurements doc):

1. **Redundant build.** Each of 16 agents independently `git clone` + `mix deps.get` +
   `mix compile` the same repo (1348 `.beam` files × 16). Same work, 16 times.
2. **CPU saturation.** Those 16 simultaneous compiles peg CPU at 99%; the `after_create` hook
   took **mean 249 s** (min 243, max 257) — vs ~30–60 s for a solo build. Tight clustering =
   contention signature. **This is the dominant cost and the same root cause as #1.**
3. **`:emfile` crash (separate defect).** All 16 agent sessions were attached to each of the 5
   opencode slots; each slot's `:poll_session` loop spawns a `tmux display-message` subprocess
   (FDs) on every poll. ~5×16 poll-spawns + 16 compile subprocess trees exhausted the open-FD
   `ulimit` → `Aiur.Tmux` crashed → cascaded through all 5 `Opencode.Slot` GenServers → node
   down. **Prewarm does NOT fix this** — it needs its own fix (slot poll fan-out + `ulimit -n`).

Bonus: `pre_warmed_sessions: 5` only gates *display* (5 agents reach "Starting claude…", 11 sit
at "Warming up…"). It does **not** throttle the compile storm — all 16 compile regardless. The
slot count and `max_concurrent_agents` are mismatched.

## Prewarm direction (operator's product constraints — IMPORTANT for the brainstorm)

The shipped/branch approach (#377) and the current `.aiur/hooks` model both require the **user
to author repo-specific shell** (`git clone …`, `mix deps.get && mix compile`). **The operator
does not want users writing repo-specific build code** (and especially not "have an agent
generate custom hooks"). Ranked preference:

1. **Best:** a **repo-agnostic** prewarm that **`aiur init` sets up on its own** — no
   user-written build code.
2. **Acceptable fallback:** an **opt-in, optional** optimization at the end of `aiur init`,
   where the user is handed a prompt to feed an agent to write custom hooks.

### What #377 ALREADY built (read before designing — do NOT rebuild it)

Branch `feat/warm-main-base` (unmerged, ~10 commits) already implements the warm-base
**mechanism**:
- `src/lib/aiur/repo_base.ex` — a `RepoBase` GenServer maintains **one** warm checkout per repo
  at `~/.aiur/repo/<owner>/<name>`, deps installed + compiled. `ensure_fresh/1` fetches
  `origin/main` and rebuilds only when main moved, serialized so parallel dispatches don't race.
- Per dispatch, `Workspace.create_for_issue` calls `ensure_fresh`; the workspace spins off the
  base (copy / `git worktree`); the base path is exported to hooks as `$THIS_REPO_BASE`.
- `aiur init` prints a prompt the dev pastes to their coding agent, which writes repo-specific
  `base_setup` (build the base) + `after_create` (spin off + incremental build) hooks.
- Config added: `base_setup` hook, `repo_base_poll_seconds` (background poll, default 0).
- Measured on aiur-self: ~5–6 min of "warming up" → seconds.

**Two gaps #377 leaves — this IS the design work:**
1. **Lazy, not eager.** The base build starts during the *first dispatch* (serialized through
   `RepoBase`), so the base is NOT ready before agents start — the opposite of the goal. The
   unmerged follow-up wants eager startup pre-warm + a loading bar in the agent list (3 open UX
   decisions in the braindump).
2. **Still requires dev-authored `base_setup`/`after_create` hooks** — so #377's design is the
   operator's *fallback* (option 2 above), not the preferred agnostic path. Removing the
   hook-authoring requirement is the NEW contribution.

### The agnostic seam to explore (brainstorm's job)

The expensive step is the **compile**, and it's repo-specific — which is why #377 pushed it to
dev hooks. Two ways to remove the user-written-hook requirement:
- **Toolchain detection at init** — sniff `mix.exs` / `package.json` / `Cargo.toml` / `go.mod`
  and fill the base build command automatically (aiur does **no** detection today — confirmed).
  Exotic repos fall back to the opt-in agent-written hook.
- **Copy-on-write spin-off** — materialize each workspace from the built base via APFS
  `clonefile`/`cp -c` (macOS), `cp --reflink` (Linux btrfs/xfs), or `git clone --local`:
  near-instant, carries `_build`/`deps`, compile happens **1×**. Still needs the base built once
  (so still needs a build command — detection or a one-line prompt), but removes per-workspace
  build shell entirely.

**Code seam (from scouting):** `src/lib/aiur/workspace.ex:21-24` `create_for_issue/2` — insert a
`materialize_from_base` step between `ensure_workspace` and `maybe_run_after_create_hook`.
`RepoBase` (on #377) is the base maintainer to build on. Other anchors:
`workspace.ex` `hook_env/0` already exports `$THIS_REPOSITORY_URL` from `tracker.github.repo`;
`init.ex:220` is the workspace-root prompt; init scaffolds `.aiur/hooks` **verbatim** from
`.aiur/examples/hooks.example` (no templating); `workflow.ex` resolves `hooks_file:`.

### Prior art to read
- `git show feat/warm-main-base:docs/brainstorms/2026-06-17-warm-base-prewarm-braindump.md`
  (eager prewarm + loading bar; 3 open UX decisions: startup-only vs mid-run re-warm; first-run
  wait UX; build-label granularity).
- `git show feat/warm-main-base:docs/brainstorms/2026-06-17-warm-main-base-requirements.md` and
  the plan `docs/plans/2026-06-17-001-feat-warm-main-base-plan.md`.
- `git diff main...feat/warm-main-base` for the implementation.

### Next steps for the prewarm work
1. Finish the **brainstorm** → write a requirements doc in `docs/brainstorms/`.
2. **`/ce-plan`** → **deepen plan** → **work** → **code review** (operator asked for the full
   loop; "use plenty of effort, don't skimp").
3. **Re-run the measurement throttled** to capture the full clone→boot→first-turn→first-message
   pipeline the crash hid: `max_concurrent_agents` 4–6, raise `ulimit -n` before launch, align
   `pre_warmed_sessions` with the agent cap. Then compare against the prewarm build.

## What shipped today (all on main, green)

- **#395** (`c68116d`) — split inline `hooks:` out of `.aiur/config` into `.aiur/hooks`
  (`hooks_file: hooks`); collapsed config/example comments to 1 line; **fixed `aiurdev build`**
  to fetch deps before `mix compile --force` (was aborting on a fresh clone with no deps).
- **#397** (`51bab01`) — fixed `/aiur-status`'s `tail-agents.sh` to resolve `.aiur/config`
  (it hard-coded the legacy `.aiurconfig` and reported zero agents).

## ⚠️ Gotchas

- **`aiurdev` builds from the clone its symlink points at**, not your cwd. On this machine the
  symlink was pointing at a stale second clone (`~/github/optimism/aiur`); it's now repointed to
  the working clone (`~/github/everdred/aiur`). If `aiurdev` shows stale behavior, check
  `readlink ~/.local/bin/aiurdev`. The old optimism clone is orphaned (safe to `rm -rf`).
- **`aiur` (published, 0.0.2) predates `.aiur/`** — use **`aiurdev`** to exercise current code.
- **Flaky TUI/tmux tests.** `test/aiur/agent_list/debug_events_ticker_test.exs` and
  `test/aiur/pane_manager_live_test.exs` (`setup_live_tmux`) flake red in CI ~half the time
  (timing/runner-load sensitive). **A PR-branch green can still flake red on the post-merge main
  run** — always check the main run too, and `gh run rerun <id> --failed` to clear. Candidate
  for its own ticket. Don't treat these reds as real without re-running.
- **`aiur init` regenerates `.aiur/config` from `config.example`** (full annotated comments come
  back). Hand-collapsing comments in the committed `.aiur/config` is ephemeral — init overwrites
  on the next run. If we want lean config output, change the **template**, not the dogfood file.
- **The 20-agent / no-compile-sharing config CRASHES the machine** (`:emfile` + CPU). Throttle
  any re-run (4–6 agents, raise `ulimit -n`).
- **Never `git add -A`** at repo root (`elixir/` is gitignored; stage paths explicitly).
- **Don't merge without operator go-ahead.** Run checks from `src/` (`mise exec -- mix …` or
  `make build|lint|coverage|dialyzer`); watch CI to completion (`gh run watch <id>
  --exit-status`) AND the post-merge main run.

## Open tickets (GitHub, label `agent:todo`)

- **#396** (new) — `init: default workspaces to ~/.aiur/workspaces/<repo>/<issue>; drop
  human-review comment` (bundles workspace-root default change + repo namespacing + a comment
  deletion; has 2 unsettled design decisions: repo-segment format and migration).
- **TO FILE** — the `:emfile` crash (Finding 3): slot poll fan-out + `ulimit -n`. Not yet filed.
- **Candidate** — flaky TUI/tmux tests.
- Existing backlog: #387 `aiur message <issue>` CLI · #385 outdated-CLI notice · #384 reap stale
  artifacts · #383 `.aiurconfig` debug setting · #382 agents use /aiur-agent skill · #379
  reactivate on PR comments · #375 arrow-key slot adjust · #371 read-only dashboard · #370 slim
  agent pre-prompt · #369 tmux pane titles · #366 agent-list theme · #365 RC chat title · #344
  upstream issue sync · #341 max-duration pauses.

## Skills / tooling

`/aiur-status` = operator monitor (tails each workspace's `logs/agent.md`; now reads
`.aiur/config`). `/aiur-agent` = cross-ticket event pub/sub (what dispatched agents use).
`release` skill cuts an npm release. Debug runs: `aiurdev --debug` writes per-agent logs to
`~/.aiur/logs/<session>/log/aiur.<id>.log` plus the orchestrator `aiur.log` — these are the
source for phase timing (events are ISO-timestamped; orchestrator uses local tz, `agent.md`
uses UTC).

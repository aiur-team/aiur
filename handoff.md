# HANDOFF — aiur dogfood loop, continuing on a bigger box

_Last updated: 2026-06-23. Punted from a 12-core MacBook (CPU-bound at 3 agents — see "The CPU
ceiling" below) to a machine with more cores. Prewarm is shipped + verified; this is the
ongoing dogfood/debug loop._

## The goal (current `/goal` — carry this forward verbatim)

> Triage open issues #266–#443 — quick-spike each, close the genuinely outdated ones, and label
> every agent-doable one `complexity:5` + `agent:todo` (reassessing even the human-review-tagged
> tickets, since most are agent-doable) so aiur picks them up. Then run the aiurdev debug loop:
> launch it, monitor agents as they work the backlog while watching for CPU bottlenecks and
> confirming prewarm is working, debug and route any issues found (file an `agent:todo` ticket —
> preferred — or self-fix via the CE loop when it needs your input or isn't agent-safe), and
> review + merge agents' fix PRs as they land until the queue is worked down.

**Phase 1 (triage): DONE** — 7 closed as outdated, 21 labeled `agent:todo`+`complexity:5`.
**Phase 2 (debug loop): IN PROGRESS** — many fix PRs merged (below); blocked from scaling by the
CPU ceiling. Your job: continue phase 2 on the bigger box until the queue is worked down.

## TL;DR for the next machine

1. `git checkout main && git pull` (all the fixes below are on `main`; the old `feat/prewarm-base`
   work is merged).
2. Read **"The CPU ceiling"** — it's why we punted. Then **land #465 first** (it unlocks scaling),
   or just run more agents because you have more cores.
3. `aiurdev build` → set concurrency in `.aiur/config` → `aiurdev --bg --debug` → verify prewarm
   `:ready` → monitor agents + load → review/merge PRs as they land → route new issues as
   `agent:todo`. The `aiur-run` skill (`.claude/skills/aiur-run`) is the full operator playbook.

## What this session merged (the loop's output so far)

- **#439** — #431 per-instance aiur identity (cwd-keyed node/tmux/socket) + env scrub so an inner
  aiur can't reap the outer. **A second aiur from a different repo root now coexists** — so this
  new machine's run won't collide with anything.
- **#441** — prewarm: trust base `mise.toml`, surface `base_build` failures.
- **#444** — flaky-test global-state leak fixes.
- **#451** — `aiur-run` operator skill.
- **#452** — #337 orchestrator status timing flakes.
- **#458** — #453 clean-stop: `aiurdev stop` reaps the whole agent tree by cwd. **Validated** — but
  see #468 caveat below.
- **#457** — #409 FD footprint: caps the attach N×M fan-out (the `:emfile` driver).
- **#460** — #449 lean `--bg` headless mode + **`--max-agents` flag** + `agents` status command.
- **#462** — agents on the `its-applekid` machine add `Co-authored-by: its-everdred`; never mention
  Claude/AI in commit/PR text. (Already in the shared agent prompt.)
- **#463 / #464 / #466** — three more flaky-test fixes (#446 AIUR_DEBUG, #459 ls_remote_ticker,
  #448 debug-events). These make agent CIs reliable.

## The CPU ceiling (READ before scaling — this is why we punted)

The 12-core MacBook **melts at 5 agents** (load 115–129) and even **bursts to ~129 at 3** when all
agents hit `mix test` at the same moment. Root cause: each agent runs the **full `mix test` suite
(~70s at 100% CPU)** during its CE loop; N concurrent suite runs saturate the cores. `max_concurrent_agents`
caps the agent *count* but nothing caps collective CPU. Stable steady-state at 3 is load 2–9, but the
test-sync **bursts** are dangerous.

- **#465 is the structural unlock** (`agent:todo`, filed this session): CPU-aware throttling — a global
  heavy-op semaphore (only K agents run `mix test`/`compile` at once), and/or load-gated dispatch,
  and/or affected-tests-only during the loop. **Prioritize #465**, then raise `max_concurrent_agents`.
- On a box with more cores you can run more agents right away — but #465 still makes it robust.

## Linux-specific edge cases (⚠️ the next box is Linux — this whole loop ran on macOS)

Everything above was exercised on a Mac. The Linux box may surface **new bugs** in these spots —
re-verify each, and **file `agent:todo` tickets** for anything that breaks:

- **CoW materialization path flips.** macOS used `cp -c` (APFS clonefile); Linux uses
  `cp --reflink=auto -a` (`workspace.ex`, U6). True reflink needs **btrfs/XFS** — on **ext4** it
  silently falls back to a **full copy**: slower materialize + much more disk per workspace. Watch
  boot→materialize time and disk under `workspace.root`; if it's slow/heavy, reflink isn't firing and
  prewarm's CPU/disk win shrinks.
- **Linux load average ≠ macOS.** Linux counts **D-state (uninterruptible I/O wait)** in the load
  number, so disk-bound CoW copies + concurrent git/compile can push load high from **I/O**, not just
  CPU. The "load < ~2× cores" heuristic may misread — cross-check actual CPU (`top`, `mpstat`,
  `/proc/loadavg` vs `vmstat`) before concluding it's a CPU meltdown. The 3-agent ceiling we hit is a
  macOS/12-core number; recalibrate it here.
- **`:emfile` / FD limits differ.** Linux default `ulimit -n` and per-process FD accounting differ
  from macOS; `aiur-engine.sh` raises it, but re-watch for `:emfile` (#409) as you scale agents.
- **Orphan reap / reparenting (#468).** Linux reparents orphans to PID 1 or a subreaper
  (`PR_SET_CHILD_SUBREAPER`); the shutdown-straggler behavior may differ from what we saw. The cwd-reap
  backstop uses `lsof -d cwd` (works on Linux); `readlink /proc/<pid>/cwd` is the native fallback if
  `lsof` is missing.
- **Bigger box = higher ceiling.** More cores means you can likely run more than 3 agents right away —
  ramp up while watching *CPU* (not I/O-inflated load). #465 still makes high concurrency robust.
- Codex backend is already Linux-configured (`.aiur/config` `writableRoots` → `/home/applekid`,
  `/home/orangekid`).

## Clean-stop status (#458 + the new #468)

- `aiurdev stop` now reaps the agent tree (no more manual orphan hunts in the normal case).
- **#468** (filed this session): under **heavy mid-`mix test` load** the reap isn't fully synchronous
  before `System.halt` — a **straggler can survive**. Until #468 lands, after every `aiurdev stop`
  run the cwd-reap backstop:
  ```bash
  for pid in $(pgrep -f 'claude|codex|beam.smp|opencode|mix'); do
    c=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//')
    case "$c" in *aiur-workspaces*|*.aiur/repo*) kill -9 "$pid";; esac
  done
  ```
  Safe because Claude Code's own cwd is the repo, not a workspace.

## The backlog (where the work is)

- **`agent:todo` (dispatch-ready):** `#465` (CPU throttle — PRIORITIZE), `#468` (shutdown straggler),
  `#376` (warm-pool cap), `#447` (core_test flake), `#461` (subscription_store flake).
  _(The GitHub label-search index lags; trust `gh issue view`. `#376/#447/#461` were just reset from
  `in-progress`→`todo` for clean cross-machine pickup.)_
- **WIP preserved on GitHub branches** (agents resume by pulling these): `aiur/376` (has **draft PR
  #467** "Size warm pool without capping opencode slots"), `aiur/447`, `aiur/461`.
- **Broader doable backlog:** ~22 `complexity:5` tickets from the #266–443 triage are **not yet
  `agent:todo`** — promote them in batches as you scale (`gh issue edit N1 N2 … --add-label agent:todo`).

## Operator procedures (the `aiur-run` skill has the full version)

- **Config** (`.aiur/config`): set `agent.max_concurrent_agents` AND `pre_warmed_sessions` **both = your
  target** (#376: `pre_warmed_sessions` still hard-caps live agents). Currently `3/3` — raise on the
  bigger box. Never `aiurdev init --force` (clobbers config). `tracker.kind: github`, repo
  `its-everdred/aiur`, `label_prefix: agent`, routing `4/5 → claude`, `prewarm.enabled: true`.
- **Launch:** `aiurdev build` (force release rebuild) → `aiurdev --bg --debug` (detached, logs under
  `~/.aiur/logs`). Refuses if `$TMUX` is set. Never `--test`/`--test3` (resets sandbox tickets).
- **Verify prewarm every launch:** base at `~/.aiur/repo/its-everdred/aiur/.aiur-base-built`; log reaches
  `prewarm:phase … :ready`; workspaces materialize in seconds (CoW), not per-agent cold builds.
- **Monitor:** `/aiur-status` (loop `2m`); watch `uptime` load — healthy if it stays under ~2× cores.
  Watch for `:emfile` in the log (#409 mostly fixed) and the test-sync bursts (#465).
- **Stop:** `aiurdev stop`, then the #468 cwd-reap backstop above.
- **On a load spike toward danger:** stop, reap by cwd, lower concurrency, relaunch.

## Conventions (enforced; already in the agent prompt / CLAUDE.md)

- Commit messages **3–7 words**, **never mention AI/Claude/models**.
- `its-applekid` author → add `Co-authored-by: its-everdred <kevinweaver2@gmail.com>` trailer (#462).
- Tickets the operator opens get `agent:todo`. **Merge is operator-authorized** (agents open/ready PRs,
  don't self-merge). Use targeted `git add`, never `-A` (there's a stray `.aiur/config.bak`).
- **NEVER read `.env`/secret files.** `.aiur/config` is gh-auth (no tokens) — safe.

## Gotchas

- Flaky CI: each agent PR's CI may hit a random suite flake — **re-run to green** (the merged flaky
  fixes + remaining `#447/#461` shrink this). Don't treat one flaky red as real.
- GitHub secondary rate-limit on rapid mutations: a single multi-issue `gh issue edit N1 N2 …` is one
  operation and bypasses it; loops trip it.
- Leftover `agent:in-progress` labels make the orchestrator **resume the wrong tickets** on relaunch —
  clear them before launching (we hit this twice).

## Next steps for the new machine

1. Pull `main`, `aiurdev build`, set concurrency for your core count, launch.
2. **Land #465** (CPU throttle) → then scale `max_concurrent_agents` up confidently.
3. Work the backlog: flaky fixes `#447`/`#461`, `#376`, `#468`, then promote + work the broader 22.
4. Review + merge PRs as they land (`/code-review` or green/red); route new issues as `agent:todo`.
5. Keep verifying prewarm `:ready` and watching load; reap stragglers per #468 until it's fixed.

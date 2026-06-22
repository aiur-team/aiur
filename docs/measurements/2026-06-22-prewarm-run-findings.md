# Prewarm measurement run — findings (2026-06-22)

Measurement run to inform the warm-base prewarm work (#377). Goal per the handoff:
measure *where* startup time/cost actually goes before designing the prewarm, and
decide what optimizations are worth it.

**Bottom line:** one run with `max_concurrent_agents` effectively 16 produced **three
compounding bottlenecks** and **crashed before a single agent did useful work**. The
expensive `after_create` hook (clone + `deps.get` + `compile`) took **~249 s mean per
agent** (vs. ~30–60 s for a solo build) purely from self-contention, then the node died
on file-descriptor exhaustion. This strongly validates the prewarm thesis: the per-agent
clone+compile is redundant *and* the dominant cost.

## Run under measurement

- Session log: `~/.aiur/logs/20260622T165848Z-34496/log/` (persists; `aiur.log` =
  orchestrator, `aiur.<id>.log` = per-agent).
- Config (this run): `kind: claude`, `max_concurrent_agents: 20`, `pre_warmed_sessions: 5`,
  `max_turns: none`, `polling.interval_seconds: 30`, `bypassPermissions`.
- 16 `agent:todo` tickets detected and dispatched at once: 339, 341, 344, 365, 366, 369,
  370, 371, 375, 379, 382, 383, 384, 385, 387, 396.
- `after_create` hook per workspace: `git clone` → branch → `mise install` →
  `mix deps.get` → `mix compile`.

## Timeline (local time, −07:00)

| Time | Event |
|------|-------|
| 09:58:48.907 | aiur boot start |
| 09:58:51.884 | first dispatch (issue 339) — **boot→dispatch ≈ 3.0 s** |
| 09:58:51.9 → 09:58:56.2 | all 16 `after_create` hooks start (serial dispatch, ~0.27 s apart) |
| 09:58:58.925 | `do_seed_pairing_check`: `known_slots=[1,2,3,4,5]`, pairs first 5 agents (339,341,344,365,366); **11 agents active but unpaired** |
| ~09:59:26–32 | dep/beam output lands in each `_build` (`mix` still not returned) |
| 10:02:57 → 10:03:18 | all 16 `after_create` hooks finally return — **mean 249 s** |
| 10:03:21.697 | first `:emfile` (FD exhaustion); `Aiur.Tmux` GenServer crashes |
| 10:03:21–22 | cascade: all 5 `Opencode.Slot` GenServers terminate |
| 10:03:29.114 | last log line — node down |

Net: ~4.5 minutes, 16 agents, **zero productive turns** before the crash.

## Finding 1 — Redundant per-agent clone + compile

Each of the 16 agents independently cloned the repo and ran `mix deps.get` + `mix compile`,
producing **1348 `.beam` files per workspace × 16**. This is the same build, 16 times. It is
exactly the work a shared warm base would do **once**.

Evidence: `Workspace hook ok hook=after_create … output_tail="Cloning into '.'… exqlite …
phoenix … (truncated)"` for every agent; `find …/_build/dev/lib -name '*.beam' | wc -l` = 1348
in each workspace.

## Finding 2 — CPU saturation from N simultaneous compiles (the dominant cost)

`after_create` hook wall-time, all 16 (sorted):

```
383 243.2s   379 243.4s   369 243.8s   396 246.0s
370 246.1s   385 246.9s   341 247.4s   382 247.8s
375 250.2s   339 250.6s   371 250.8s   387 251.2s
365 253.3s   344 255.9s   384 256.1s   366 256.6s
                          n=16  min=243s  max=257s  mean=249s
```

The **tight clustering** (all within a 13 s band, all finishing together ~10:02:57–10:03:18)
is the signature of CPU-bound contention: 16 compiles sharing a fixed CPU pool each stretch to
~N×(solo time) and complete simultaneously. Observed CPU was pegged at ~99% throughout; top
consumers were `beam.smp` (≈17 instances = main node + opencode slots + the per-hook `mix`
VMs). A solo warm `mix compile` of this repo is ~30–60 s, so 16-wide inflated each hook ~4–8×.

> Note to confirm on a throttled run: dep/beam files appeared in `_build` ~40–90 s in, but the
> hooks didn't *return* for ~249 s. The gap is consistent with CPU starvation stretching the
> app-compile + protocol-consolidation tail, but a low-concurrency run is needed to cleanly
> separate solo cost from contention cost.

**Implication:** this is the same finding as #1 wearing a different hat. Prewarming a shared,
pre-compiled base (compile once; clone-or-copy/symlink into each workspace) collapses 16×
compile → 1× and is the direct CPU relief. The win is real and large.

## Finding 3 — The crash: file-descriptor exhaustion (`:emfile`)

Distinct from CPU; this is what actually killed the run.

```
GenServer Aiur.Tmux terminating, ** (stop) :emfile,
  :erlang.open_port({:spawn_executable, "/opt/homebrew/bin/tmux"},
    {:args, ["-L","aiur-kevin","display-message","-p","-t","%10","#{pane_id}"]})
```

Mechanism, from the crashed `Opencode.Slot` state: **all 16 agent sessions were attached to
every one of the 5 slots** (`attached_identifiers: [339…396]` on each slot). Each slot runs a
`:poll_session` loop, and **each poll spawns a `tmux display-message` subprocess** (an OS port
= FDs). So ~5 slots × 16 sessions polling in a loop spawned tmux ports continuously, on top of
16 concurrent clone+compile subprocess trees. The BEAM exceeded the open-FD `ulimit` →
`Aiur.Tmux` couldn't `open_port` → crash → cascade through all 5 slots → node down.

This is **not** fixed by prewarm. It's a separate scaling defect:
- slot/polling fan-out (every session attached to every slot; poll-by-subprocess-spawn), and/or
- `ulimit -n` too low for the configured concurrency.

Worth its own ticket. Candidate fixes: don't attach all sessions to all slots; replace
poll-via-`tmux`-subprocess with a long-lived query / cached pane id; raise `ulimit -n`; cap
concurrent slot polling.

## Bonus finding — slot pool (5) gates display, not warming

`pre_warmed_sessions: 5` → only 5 slots. The first 5 dispatched agents pair to them and show
"Starting claude…"; the other 11 sit at "Warming up…". But the *expensive* `after_create` work
runs for all 16 regardless of pairing — so capping slots does **not** throttle the compile
storm. With `max_concurrent_agents: 20` and only 5 slots, 11–15 agents queue for display while
all 16 still hammer the CPU. The slot count and the concurrency cap are mismatched.

## What we could NOT measure (and how to get it)

The crash hit ~3 s after the last hook finished, so no agent reached its first `turn/started`
or `agentMessage`. The full pipeline **clone → hook → boot → first turn → first message** per
agent is still unmeasured.

To get a completable run, throttle so the box survives:
- Drop `max_concurrent_agents` to ~4–6 (matches CPU cores; removes the compile storm), **and/or**
- `ulimit -n` raised substantially before launch (mitigates `:emfile`), **and/or**
- align `pre_warmed_sessions` with `max_concurrent_agents`.

A 4–6 agent run will yield clean solo-vs-contended compile numbers and the boot→first-message
tail, which is what the prewarm design needs next.

## Recommendations for #377

1. **Prewarm a shared compiled base** (compile once per poll/dispatch cycle; share into
   workspaces). Directly removes Findings 1 & 2 — the dominant cost.
2. **File a separate ticket for the `:emfile` crash** (Finding 3) — slot poll fan-out + FD
   budget. Prewarm alone won't prevent it at high concurrency.
3. **Reconcile `pre_warmed_sessions` vs `max_concurrent_agents`** so slot count isn't a silent
   display bottleneck while compiles run unthrottled.
4. **Re-run throttled (4–6 agents)** to capture the full per-phase pipeline timing.

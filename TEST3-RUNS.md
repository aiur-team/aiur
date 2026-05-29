# test3 run log

Running journal of `aiur --test3` iterations. The goal: drive the 3 sandbox tickets (#99 function_a → #100 function_b → #101 function_c) through the full blocker-chain to `agent:human-review` as fast as possible, prioritizing unblocking over other work.

Machine-readable per-run timings live in `.aiur-test3-runs.jsonl` (one JSON line per completed run). This doc captures the qualitative story: what we changed, what broke, what we learned.

## Baselines + targets

- **Baseline (run #1)**: 1598s = 26:38 total, no fixes
- **Push → blockee wake**: ~1s (already excellent, no work needed)
- **Bottleneck identified**: each agent's first turn paid 3-4 min for cold `mix deps.get` because workspace pre-warm hooks silently failed

## Run history

### Run #1 — baseline (2026-05-28 19:16)

- **Outcome**: complete
- **Total elapsed**: 1598s (26:38)
- **Per-ticket** (from `Issue deactivated` log lines, work.start at ≈19:17:36):
  - #99: 10:32
  - #100: 14:33
  - #101: 25:59
- **Chain timing**:
  - #100 declared blocker at 16s (work.start → declare)
  - #101 declared blocker at 56s
  - #99 push at 12:43 → #100 wake at +1.0s
  - #100 push at 15:24 → #101 wake at +1.0s
- **Issues found**:
  - Hook silent failure → every agent re-ran `mix deps.get` itself (3-4 min/agent)
- **Conclusion**: chain semantics solid, push→wake latency excellent; the time sink is per-agent boot + work cycle, dominated by cold deps.

### Run #2 — destroyed (2026-05-28 19:45)

- **Outcome**: terminated mid-run
- **#99 done at 10:52, #100 done at 12:21**
- **Failure mode**: #101's verification step launched `./scripts/aiur --test --force --allow-remote` from inside its workspace. The recursive script ran `stop all` (pkill'd the operator BEAM) and `mix aiur.test.reset` (wiped sandbox tickets back to `agent:todo`). Operator tmux session and BEAM both died. Run #2 results never reached the JSONL — `agent:human-review` labels for #99/#100 got reset.
- **Changes added before kill**:
  - `c1` bumped hook timeout 60s → 10min + added `aiur_perf workspace_hook phase=done elapsed_ms=N` log line (commit `08630eb`)
  - `c2` per-ticket completion timing in `aiur-test3-timer` (commit `0585651`)
  - `c3` compact-JSON timer output (commit `6b8c2b4`)
- **Observation**: hook elapsed showed 7.7-18s — far less than the 3:30+ I measured manually. Hook was failing silently and timeout bump alone didn't help.

### Run #3 — diagnostic (2026-05-28 20:24)

- **Outcome**: killed early after capturing the diagnostic data we needed
- **Changes added during run**:
  - `c4` hook diagnostics: drop `>/dev/null 2>&1`, log a 512-byte output_tail on success (commit `fcf7ec0`)
  - `c5` P0 agent guard: `AIUR_AGENT_WORKSPACE` env marker + PWD-pattern check in `scripts/aiur` so any subcommand exits 78 from inside `*/aiur-workspaces/*` (commit `e79ad84`)
- **Root cause uncovered**: workspace_hook output_tail revealed
  ```
  Protocol 'inet_tcp': the name aiur-orangekid@127.0.0.1 seems to be in use by another Erlang node
  ```
  Hook inherited operator's `ERL_AFLAGS`/`RELEASE_NODE`/`RELEASE_COOKIE`; `mix` failed instantly. The `&&` chain short-circuited, deps + compile never ran. `Aiur.AgentEnvironment` had a `scrub_shell_command/2` helper already — it just wasn't applied to hooks.

### Run #4 — ERL_AFLAGS scrub + complexity:1, degraded by stale guard (2026-05-28 20:29)

- **Outcome**: degraded — chain completed for #99 + #100 but #101 ran `./scripts/aiur --test` from its workspace and reset all 3 tickets back to `agent:todo` (workspace's `scripts/aiur` was the pre-guard snapshot from `main`, didn't have the `e79ad84` guard).
- **Per-ticket** (work.start at 20:34:22):
  - #99: done at 7:31 (**3:01 faster than run #1**)
  - #100: done at 16:30 (1:57 slower; paused waiting for #99 instead of stubbing in parallel)
  - #101: destroyed mid-integration when its own verification step recursively launched aiur
- **Hook diagnostics confirmed scrub fix**: workspace_hook output_tail now shows actual deps being downloaded + compiled (cc_precompiler, credo, etc.) instead of the `Protocol 'inet_tcp'` error. After_create hooks: 3:54 / 4:08 / 4:12 (parallel, ~4 min wall-clock).
- **New bug surfaced**: agent workspaces clone from `origin/main` at the hook step. The script-level + TestReset-level guards I added on the `kevin/e2e-pubsub-test` branch never reach the workspace because the workspace's own `scripts/aiur` and `mix aiur.test.reset` are the older pre-guard snapshot.
- **Changes added during run**:
  - `c8` `Aiur.TestReset.run/1` refuses with `:agent_workspace_blocked` when `AIUR_AGENT_WORKSPACE` is set or `repo_root` contains `/aiur-workspaces/` (commit `d17406b`)
  - `c9` workflow `after_create` hook now clones the operator's working branch (`kevin/e2e-pubsub-test`), falling back to `origin/main`, so fresh workspaces include the guards (commit `6a6707a`)

## Changes ledger

| ID | Commit | Effect |
|----|--------|--------|
| c1 | `08630eb` | Hook timeout 60s → 10min + elapsed_ms log |
| c2 | `0585651` | Timer captures per-ticket completion timestamps |
| c3 | `6b8c2b4` | Timer writes one-line JSON per run |
| c4 | `fcf7ec0` | Hook output captured + logged (output_tail diagnostics) |
| c5 | `e79ad84` | `scripts/aiur` refuses to run from agent workspaces (P0 guard, layer 1) |
| c6 | `e4682e2` | Workspace hooks run through ERL_AFLAGS scrub — hooks now actually fetch deps |
| c7 | `e4682e2` | Sandbox tickets get `complexity:1` on reset |
| c8 | `d17406b` | `Aiur.TestReset.run/1` refuses when called from inside an agent workspace (P0 guard, layer 2 — the depth that always runs even when the workspace ships a stale `scripts/aiur`) |
| c9 | `6a6707a` | Workspaces clone from `kevin/e2e-pubsub-test` instead of `origin/main` so the guards reach the workspace immediately |

## Open optimizations to consider

- Encourage stub-then-fetch over pause-and-wait so blockees do real parallel work (run #4 #100 paused instead of stubbing — cost ~2 min)
- Replace per-workspace `git clone` with `git worktree add` (would reuse the operator's pack files; saves 3-5s per workspace, but adds .git lock contention risk)
- Agents independently re-read SKILL.md and re-explore the codebase on every fresh boot (60s of read-only exploration per agent that could in principle be pre-seeded — but bounded LLM thinking time would still dominate)

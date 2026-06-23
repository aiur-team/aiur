# Handoff - Aiur dogfood loop paused

Last updated: 2026-06-23. Aiur is paused/stopped by operator request. Do not restart Aiur, change agent labels, or continue the dogfood loop until the operator explicitly says to resume.

## Current State

- `scripts/aiurdev status` reports no running node:
  `aiur: no running aiur node at aiur-orangekid-5c1b32aea9@127.0.0.1; start aiur and try again`
- Open PRs: none.
- Local checkout is dirty with user/local edits. Do not revert these:
  - `.aiur/config`
  - `.env.example`
  - `handoff.md`
  - untracked `.aiurconfig`
  - untracked `AIUR.md`
- Main may need a normal merge pull later, but preserve local edits. The operator previously allowed pulling main as long as local edits stay intact.

## Recent Completed Work

- PR #490 for issue #334 was salvaged, reviewed, and merged.
  - PR: https://github.com/its-everdred/aiur/pull/490
  - Merge commit: `5da7524e27b2a22a273ba2d1dc659586b2156309`
  - Closing issue #334 is closed, though it may still have stale agent/human-review labels.
- Earlier merged PRs in this run:
  - #476 closed #437
  - #467 closed #376

## Active Queue Snapshot

`agent:todo` open issues at handoff:

- #492 `aiurdev status sees bg agents while RPC commands report no running node` - `model:codex`
- #491 `Move alert sound mappings into .aiur with alerts.example`
- #488 `Background aiur daemon disappears without crash record during active run`
- #487 `Design workspace-local log layout and pause for operator decision`
- #489 `aiur-status tails stale workspace root and misses active background runs`
- #486 `aiurdev agents crashes on structured Codex activity events` - `model:codex`
- #485 `Resume agents do not ingest PR comments posted while offline`
- #484 `GitHub tracker skips agent:rework issues despite active_states including rework`
- #483 `Audit and slim down tmux usage in background mode`

Stale `agent:in-progress` labels are present even though Aiur is stopped:

- #482 `Run agent aiurdev IR tests in isolated sandboxes` - `model:codex`
- #481 `Make aiur run/status skills discoverable by Codex`
- #479 `Agents reproducing load-sensitive flakes spawn unbounded CPU load-generators that starve sibling agents` - `model:codex`
- #477 `Load gate (#465) is off by default...` - `model:codex`
- #469 `Config + init: per-complexity model and effort selection...` - `model:codex`
- #468 `Shutdown reap (#458) leaves a straggler under heavy mid-test load...` - `model:codex`

Do not assume these are actually running. They likely need label cleanup before any restart, but the operator asked to pause all work, so no cleanup was performed.

## Important Risks

- Keep concurrency at 1 until the load/process bugs are fixed.
- Do not reactivate #447 without operator confirmation. It previously spawned many `yes` CPU load generators and pause did not stick.
- #479 tracks the unbounded load-generator problem.
- #482 tracks nested/manual `aiurdev` IR tests needing their own sandbox. Before that is fixed, agents that run `scripts/aiurdev --test` from their own workspaces can interfere with the operator's main Aiur session.
- #486 means `scripts/aiurdev agents` may crash on structured Codex activity events. Prefer `scripts/aiurdev status` plus logs until fixed.

## Alert Flag Finding

There does not appear to be a dedicated built-in alert topic for "agent killed" or generic "agent ended." Current alert coverage includes `agent.paused`, `agent.unpaused`, `agent.error.tokens_exhausted`, phase ends like `agent.work.end` / `agent.review.end`, and tracker events such as human-review labels, PR merged, and issue state changes. If this matters operationally, file a new `agent:todo` ticket to emit explicit termination alerts such as `ticket.<id>.agent.killed` or `ticket.<id>.agent.terminated`, with default alert mapping and tests.

## If Resuming Later

1. Confirm with the operator before starting anything.
2. Recheck `scripts/aiurdev status`, `gh pr list`, and current `agent:*` labels.
3. Clean stale `agent:in-progress` labels intentionally; do not blindly reactivate risky tickets.
4. Restart conservatively with one agent only, for example `scripts/aiurdev --bg --max-agents 1`.
5. Watch the selected ticket, Aiur logs, and process list closely for nested-run or CPU runaway regressions.
6. Review any agent PRs before merge; merge only when tests/checks are green and the behavior is verified.

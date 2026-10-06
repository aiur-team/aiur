---
ticket_id: MP-E1-C6-T01
feature_id: MP-E1
chunk_id: MP-E1-C6
bucket: 2-platform
title: aiur queue show - read model, human and JSON output
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T03]
prior_units: [U6]
prior_boundaries: [CLI #31]
prior_features: [MP-R1]
prior_findings: [MP-E1 F9]
size_owner: "CLI / npm CLI packaging (aiur-engine.sh 4224 lines) and Agent control CLI (agent_control_cli.ex 3362 lines); provisional, RC-23"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C6-T01 — `aiur queue show [--queue NAME] [--json]`

> **Plan refresh (wave 0).** Cites `45a290e3`. After MP-R1 the verb is part of
> the `build-queue` component's CLI surface; the engine arm stays in the shared
> launcher (`aiur` and `aiurdev` share it, AGENTS.md "Layout").

## Identity and outcome

- Bucket 2, MP-E1, C6, T01. Contract §3.
- **User value:** the operator and the Executor see each queue, its items in
  start order, why each waits, and how old the data is.
- **Deliverable:**
  - `Aiur.BuildQueue.show/1` returns the contract §3 map (schema_version 1).
  - PROPOSED `src/lib/aiur/build_queue_cli.ex` (`Aiur.BuildQueueCLI.run/1`)
    renders human or JSON output; `AgentControlCLI.queue/1`.
  - Engine: `queue)` arm in `aiur_engine_main`, `cmd_queue` dispatching
    `show` (mutation verbs come in C6-T02/T03), usage line.

## Dependencies and blockers

- DESIGN-E1 §3 (human layout, copy, exit codes) — the layout below is the
  recommendation and must match the approved mock-up.
- C3-T03 (server, status).

## Verified starting point (`45a290e3`)

- `AgentControlCLI.build_orders/1` (`agent_control_cli.ex:364-367`):
  `guarded/2`, `error_fun`, `exit_marker/1`.
- `BuildOrdersCLI.run/1` (`build_orders_cli.ex:21-36`) JSON vs human; sources
  carry `observed_at`, `age_ms`, `freshness` (`:232-259`, F9).
- Engine: `cmd_build_orders` (`aiur-engine.sh:2961-2991`, base64 argument
  passing), `run_control_rpc` (`:2419-2436`, 124 = timeout, outcome unknown),
  `aiur_engine_main` (`:4072-4150`), `usage()` (`:448-463`).
- `website/docs-app/scripts/check-cli-reference.sh:14-40` fails when an engine
  command or parsed flag is missing from `reference/cli.md`.
- `reference/cli.md:29, 153-159` read-only mirror commands.

## Chosen design

- JSON: exactly contract §3; `sources.*` each with `observed_at`, `age_ms`,
  `freshness`, `reasons`; `status` from the server.
- Human (recommended, pending DESIGN-E1):

  ```text
  build queue  running  observed 41s ago (current)
  paseo  60% (9/15, partial)
    pos  ticket  state     waiting on            rank
    1    #2581   waiting   #2579 pending         4 downstream · p2
    2    #2590   promoted  —                     1 downstream · p3
  ```
- `unknown`/`stale` print as `unknown`/`stale (15m ago)`, never `0`/`ready`
  (contract §1 rule 4). Titles are fetched at render time from existing
  projections only if available; never stored (privacy).
- Exit codes: 0 success; 1 refusal (`disabled`, `unsupported_tracker`,
  `store_unavailable` still print status and exit 1); 124 timeout (engine).

## Implementation steps

1. `Aiur.BuildQueue.show/1` (server call assembling the read model from
   planner output; ≤ 100 lines).
2. `build_queue_cli.ex` (≈ 120 lines).
3. `agent_control_cli.ex`: `queue/1` like `build_orders/1` (≈ 5 lines).
4. `aiur-engine.sh`: `queue)` arm, `cmd_queue` with `show` sub-verb,
   `--queue`, `--json`; usage line.
5. Docs: `reference/cli.md` row in the mirror table and a `### aiur queue`
   section; `check-cli-reference.sh` passes.

## Non-happy paths

- Daemon not running → existing `run_control_rpc` diagnostics.
- Server absent (disabled) → `status: disabled`, empty queues, exit 1 with
  DESIGN-E1 copy.

## Compatibility and rollout

New command. `aiur units --condition queued` keeps meaning "has `agent:todo`"
(`reference/cli.md:99`); the docs note the different meaning of "queued" here.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/build_queue_cli_test.exs` (PROPOSED) "json matches the contract schema" — snapshot of keys for a fixture | keys equal the §3 list | `show/1` shape |
| "stale build-order source prints stale with age" | human text contains `stale (` and JSON `freshness: "stale"`, `age_ms` | freshness rendering |
| "unknown source renders unknown, not 0" — then replace the unknown branch with `0` | test fails under that replacement (AGENTS.md unknown-path rule) | the unknown branch |
| "disabled exits 1 with status" | return 1, `status: "disabled"` | status handling |
| `src/test/aiur/agent_control_cli_test.exs` "queue/1 emits the exit marker" | marker printed | `exit_marker/1` wiring |
| `bash website/docs-app/scripts/check-cli-reference.sh` | pass | the docs section |

Mutation check: render `unknown` as `0` → test 3 fails; drop the docs section →
the CLI reference check fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue_cli_test.exs test/aiur/agent_control_cli_test.exs
bash website/docs-app/scripts/check-cli-reference.sh
```

Manual: `scripts/aiurdev --bg` from the Executor repo root, then
`scripts/aiurdev queue show` and `--json`; record output in the PR.

## Completion and handoff

- [ ] Read model, CLI, engine arm, docs in one PR.
- Dependents: C6-T02, C6-T03, C8-T01.

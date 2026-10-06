---
ticket_id: MP-R1-C9-T13
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Move the --todo verb into the orchestration component; keep MP-E1's queue verb on its own module
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C9-T10, MP-R1-C9-T12]
prior_units: [U2, U6, U8]
prior_boundaries: [CLI #31, DSP #13]
prior_features: [MP-E1]
prior_findings: [loose-2-01, loose-2-14]
size_owner: CLI (agent_control_cli.ex, agent_control_cli_test.exs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T13 — `--todo` verb moves; build-queue verbs stay with build-queue

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S16 (path-map row PR-13: "agent_control_cli.ex verbs →
  per-component CLI modules … affects E1 (queue verbs)").
- **User value:** none visible.
- **Deliverable:** `Aiur.Orchestrator.TodoCLI` (PROPOSED,
  `src/lib/aiur/orchestrator/todo_cli.ex`) holding `todo/2` and its helpers;
  `AgentControlCLI.todo/2` becomes a `defdelegate`. MP-E1's `AgentControlCLI.queue/1`
  stays a one-line delegate to `Aiur.BuildQueueCLI` — this ticket only records and tests
  that placement.
- **Non-goals:** no change to `--todo`/`--only` semantics, budget handling, or label writes;
  no merge of `--todo` into the build queue (that would be product behaviour, MP-E1/DESIGN-E1).

## Dependencies and blockers

- DESIGN-R1 §1; C9-T10; C9-T12 (same file, serialize).
- **MP-E1-C6** (queue CLI: engine `queue)` arm calling `Aiur.AgentControlCLI.queue(...)`
  and `Aiur.BuildQueueCLI`, `bucket-2-platform/MP-E1/chunks.md` C6-T01/T02). If E1-C6 has
  not merged, do the `todo` move anyway and skip the queue test; MP-R1-C11-T02 re-adds it.
- RC-20: `--todo` writes `agent:todo` through the tracker; it is (like the build queue) a
  caller of the single label-writer seam. The move does not change which seam it calls;
  after U2 the call follows U2's writer like every other caller.

## Verified starting point (45a290e3)

- `todo/2`: `src/lib/aiur/agent_control_cli.ex:852-1287` (≈435 lines), including
  `todo_runtime_deps/0`, budget helpers (`todo_budget*`, `:922-978`), `queue_todo_issue`
  (`:979`), `maybe_clear_other_todos` (`:1037`), `clear_other_todo_step` (`:1122`),
  `require_github_tracker` (`:1270`).
- Launcher: `aiur-engine.sh:617`
  `run_control_rpc "Aiur.AgentControlCLI.todo(<list>, only: …, budget_ms: …, emit_exit_marker: true)"`.
- Existing delegate pattern for feature CLIs: `build_orders/1` → `BuildOrdersCLI.run/1`
  (`agent_control_cli.ex:364-367`).

## Chosen design

Pure move behind a delegate (C9-T10 rule). The `deps` injection seam
(`Keyword.get(opts, :deps, todo_runtime_deps())`) moves unchanged, so tests keep injecting
fakes the same way. `TodoCLI` belongs to `orchestration` (it queues work for dispatch),
not to `build-queue`.

## Implementation steps

1. Move `:852-1287` to `todo_cli.ex` (< 500 lines).
2. Delegate in `AgentControlCLI`.
3. Move the `todo` test cases to `src/test/aiur/orchestrator/todo_cli_test.exs`.
4. Add the queue-placement test (if E1-C6 merged).

Estimated: ≈10 changed lines, ≈440 moved.

## Non-happy paths

Moved verbatim: partial run summary + exit marker, budget exhaustion, non-GitHub tracker
refusal, `--only` dequeue failures.

## Compatibility and rollout

No change. Rollback: revert.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator/todo_cli_test.exs test/aiur/agent_control_cli_delegation_test.exs
env -C <checkout>/packaging/npm/aiur-cli bun test
```

| Test | Expectation | Fails without |
|---|---|---|
| `todo_cli_test` (moved) | identical outputs | (moved) |
| `agent_control_cli_delegation_test "queue/1 delegates to Aiur.BuildQueueCLI and no build_queue code lives in AgentControlCLI"` | `AgentControlCLI.queue/1` body is a single delegate (source scan) and `Aiur.BuildQueueCLI` exports `run/1` | (guard for PR-13 placement; label it a regression guard) |

Manual: `scripts/aiurdev --todo <sandbox ids> --only` on a `--test` run; labels and output
match the base build.

## Completion and handoff

- [ ] `todo` lives in `orchestration`; `queue` stays with `build-queue`.
- Docs: none.
- Dependents: MP-R1-C11-T02 (PR-13 row resolved). size_owner re-resolved at ticket start
  (RC-23).

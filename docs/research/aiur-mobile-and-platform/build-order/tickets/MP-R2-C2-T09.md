---
ticket_id: MP-R2-C2-T09
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Aiur.Events facade migration batch B (orchestration)
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C2-T08]
prior_units: [U2, U7, U8]
prior_boundaries: [BUS #10, ORC #12, PRL #15]
prior_features: [MP-E1 (edits orchestrator files in wave 0, RC-19)]
prior_findings: []
size_owner: ORC owners for ci_lifecycle.ex, pause_resume.ex, command_scan.ex (look up at start per RC-23); no file may grow
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T09 — Facade migration, batch B (orchestration)

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.** No user-visible change.
- **Deliverable:** every orchestration call into `Aiur.Events.Publisher`,
  `Exchange` or `IdGenerator` goes through the `Aiur.Events` facade
  (C2-T08). Pure module-prefix rename.
- **Non-goals:** no logic change in any orchestrator module.

## Dependencies and blockers

- DESIGN-R2 §1; **C2-T08** (facade exists).
- **U2 and MP-E1 overlap:** U2 owns `src/lib/aiur/orchestrator/`; MP-E1-C1
  edits `issue_sync.ex` and `dispatch_policy.ex` (RC-19). This batch does
  not touch those two files. If U2 has an open PR on any file below, rebase
  this one-token change on it rather than blocking either.

## Verified starting point (45a290e3)

| File | Line | Call |
| --- | --- | --- |
| `src/lib/aiur/orchestrator/ci_lifecycle.ex` | 361 | `Publisher.publish(topic, payload, …)` (branches on `:deduped`) |
| `src/lib/aiur/orchestrator/ci_lifecycle.ex` | 1557 | `IdGenerator.next_id()` |
| `src/lib/aiur/orchestrator/command_scan.ex` | 316 | `Publisher.publish(…)` |
| `src/lib/aiur/orchestrator/ready_for_review_transitions.ex` | 185 | `Publisher.publish(…)` |
| `src/lib/aiur/orchestrator/lifecycle.ex` | 399 | `Publisher.set_tracked_fn(tracked_issue?)` |
| `src/lib/aiur/orchestrator/lifecycle.ex` | 410 | `Enum.each(@orchestrator_topics, &Exchange.subscribe/1)` |
| `src/lib/aiur/orchestrator/pause_resume.ex` | 1826 | `IdGenerator.reserve_durable_id()` |

Comment-only references (update wording, no code): `orchestrator.ex:29`,
`orchestrator/comment_wake.ex:842,1473`, `orchestrator/rework_gate.ex:132`.

Tests: `test/aiur/orchestrator_ci_lifecycle_test.exs`,
`test/aiur/orchestrator/event_topics_test.exs`,
`test/aiur/orchestrator/auto_subscriptions_test.exs`, pause/resume and
ready-for-review tests under `test/aiur/orchestrator*`.

## Chosen design

Same rule as C2-T08: alias swap and prefix rename only; line counts
unchanged.

## Implementation steps

1. Edit the five files in the table.
2. Update the four comments to say "the `Aiur.Events` publish boundary".
3. `make lint` (compile with warnings as errors).

## Non-happy paths

None added (delegation).

## Compatibility and rollout

None. Rollback: revert.

## Verification

- No new test: a rename's guard is the existing suites that drive each
  call site (stated in the PR body). In particular
  `orchestrator_ci_lifecycle_test.exs` asserts the `:deduped` branch at
  `ci_lifecycle.ex:361`, and the orchestrator lifecycle tests assert the
  Exchange bindings from `lifecycle.ex:410`.
- C1-T04 (supervision/rebind characterization) green: it observes
  `Orchestrator.Lifecycle` re-binding after an Exchange crash through the
  renamed call.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator_ci_lifecycle_test.exs test/aiur/orchestrator/ \
  test/aiur/events/exchange_restart_rebind_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check: n/a for a rename (no new test). Stated in the PR body per
AGENTS.md "If you cannot revert cleanly, say so" — here there is no new
test to revert against.

## Completion and handoff

- [ ] `git grep -nE "Events\.(Publisher|Exchange|IdGenerator)" -- src/lib/aiur/orchestrator` returns only nothing (or comments naming the facade).
- [ ] No file grows.
- [ ] Docs: none.
- Dependents: C4-T03 (checker can mark `Publisher`/`Exchange`/`IdGenerator` component-private once C2-T10 also lands).

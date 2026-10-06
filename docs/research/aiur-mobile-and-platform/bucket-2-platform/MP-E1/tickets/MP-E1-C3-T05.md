---
ticket_id: MP-E1-C3-T05
feature_id: MP-E1
chunk_id: MP-E1-C3
bucket: 2-platform
title: Withdrawal protocol after a dependency change (D8)
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T04, MP-E1-C1-T02, MP-E1-C1-T05, MP-E1-C1-T06]
prior_units: [U2]
prior_boundaries: [DSP #13, ORC #12]
prior_features: []
prior_findings: [MP-E1 F4, F5]
size_owner: n/a (build_queue files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C3-T05 — Withdraw `agent:todo` only from an unclaimed ticket

> **Plan refresh (wave 0).** RC-20: the removal goes through
> `Aiur.Tracker.remove_label/2` today and U2's writer later. The hold and claim
> check use the two RC-11 edges only.

## Identity and outcome

- Bucket 2, MP-E1, C3, T05. Contract §2.4.
- **User value:** when a promoted ticket stops being ready (new edge,
  reopened or failed prerequisite), it goes back to waiting if no agent has it,
  and nobody's running work is disturbed if one has (D8). AC4, AC5, AC6.
- **Deliverable:** executors for `begin_withdraw`, `withdraw`, `hold_release`
  actions (planner, C2-T04).

## Dependencies and blockers

- DESIGN-E1, C3-T04, C1-T02 (otherwise the zero-label heal re-adds todo),
  C1-T05 (hold), C1-T06 (probe).

## Verified starting point (`45a290e3`)

- A running ticket can still carry only `agent:todo` (F4,
  `orchestrator/dispatcher.ex:2523-2566`).
- Without C1-T02 the heal restores the last polled state
  (`orchestrator/issue_sync.ex:392-458`).
- `DispatchPolicy` reads `Hints.held?/1` first in `dispatch_state_decision/4`
  (C1-T05).

## Chosen design

1. `begin_withdraw(id)`: insert the hold into `Hints` (synchronously, before
   anything else), then `ClaimProbe.status([ids])` (one call for the batch).
2. Per id:
   - `:unclaimed` → intent `withdraw`, `remove_label(id, todo_label)`, outcome.
     Keep the hold until an observation shows `todo` absent, then release.
   - `:claimed` → release the hold, planner opens
     `ticket.<id>.queue.attention.dependency_changed_after_start` (C5-T02);
     no write.
   - `{:declined, _}` → treated as `:unclaimed` (a decline means not started).
   - `:unavailable` → keep the hold, no write, retry next reconcile.
3. Holds older than 3 × `reconcile_interval_seconds` without progress emit a
   log warning (not an alert) and stay — "never remove a label without proof".

## Implementation steps

1. `build_queue/withdrawal.ex` (PROPOSED), ≈ 80 lines.
2. Server: hold bookkeeping across reconciles.
3. Integration test harness running a real `IssueSync.reconcile_contradictory_state_labels/3`
   pass against the fake tracker's labels, so AC4 cannot pass vacuously.

## Non-happy paths

- **Orchestrator down:** hold kept indefinitely; dispatch cannot start the
  ticket; status shows `held (claim check unavailable)`.
- **Remove fails:** retried under C3-T04's policy; hold kept.
- **Someone re-adds todo after withdrawal:** C3-T06 marks it `overridden`.

## Compatibility and rollout

Behaviour only for queue-promoted items.

## Verification

| Test (`src/test/aiur/build_queue/withdrawal_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "AC4: new edge on promoted unclaimed item → todo removed, marker kept, next IssueSync pass does not re-add todo" | fake tracker labels `["agent:queued"]` after the heal pass | the withdraw executor (and C1-T02) |
| "AC5: claimed (running with only todo) → no write, attention action" | zero tracker calls; `dependency_changed_after_start` action | the `:claimed` branch |
| "AC6: probe unavailable → no write, hold kept" | zero calls; `Hints.held?(id)` true | the `:unavailable` branch |
| "hold is set before the probe is asked" — probe double asserts `Hints.held?` on entry | assertion holds | step-1 ordering |

Mutation check: ask the probe before setting the hold → test 4 fails; treat
`:unavailable` as unclaimed → test 3 fails.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue/withdrawal_test.exs
```

## Completion and handoff

- [ ] AC4–AC6 green; heal-pass fixture in place.
- Docs: covered by C9-T02 (concepts) and C6-T02 (CLI semantics).
- Dependents: C4-T02 (OQ-7 adoption withdraws), C5-T02.

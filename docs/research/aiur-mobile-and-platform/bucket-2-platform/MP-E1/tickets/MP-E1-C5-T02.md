---
ticket_id: MP-E1-C5-T02
feature_id: MP-E1
chunk_id: MP-E1-C5
bucket: 2-platform
title: The queue attentions - failed prerequisite and the six other causes
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C5-T01, MP-E1-C3-T05, MP-E1-C4-T06]
prior_units: [U3]
prior_boundaries: [BUS #10]
prior_features: []
prior_findings: [MP-E1 F3, F7, F9]
size_owner: n/a (build_queue files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C5-T02 — One alert per cause

> **Plan refresh (wave 0).** Topics per contract §4.3; registered in the R2
> catalog later (RC-08).

## Identity and outcome

- Bucket 2, MP-E1, C5, T02.
- **User value:** the operator learns, once, which prerequisite failed and
  every ticket it blocks (D6, AC3), and is told about the other queue faults.
- **Deliverable:** planner `attention_open/attention_resolve` actions wired to
  C5-T01 for:

| Cause | Topic | Opens when | Resolves when |
| --- | --- | --- | --- |
| prerequisite failed | `ticket.<prereq>.queue.attention.prerequisite_failed` | any edge verdict `{:failed, cause}` | no dependent edge is failed any more |
| dependency changed after start | `ticket.<id>.queue.attention.dependency_changed_after_start` | C3-T05 `:claimed` | item completes or verdict ready again |
| write failed | `ticket.<id>.queue.attention.write_failed` | 5 consecutive failures (C3-T04) | next successful write |
| merged, issue open | `ticket.<id>.queue.attention.merged_issue_open` | C4-T06 | issue closed |
| inputs unavailable | `system.queue.attention.inputs_unavailable` | any source `unknown` longer than 2 × `observation_max_age` | all sources current |
| store unavailable | `system.queue.attention.store_unavailable` | C3-T02 load error | store loads |

  (`promoted_unauthorized` is C5-T04.)

## Dependencies and blockers

- DESIGN-E1 §5 copy, C5-T01, C3-T05.

## Verified starting point (`45a290e3`)

- Pattern for one alert naming several tickets:
  `orchestrator/issue_sync.ex:573-595`.
- Blocked set: transitive dependents via `Ordering` closure (C2-T03).

## Chosen design

- `prerequisite_failed` payload refs: `prerequisite`, `blocked` (direct
  dependents first, then transitive, numbers only), attrs `cause`
  (`agent_error | pr_closed_unmerged | not_planned`). Dedupe key
  `(instance, prereq, cause)`; a changed blocked set does not re-fire (the
  read model shows the current set).
- `store_unavailable` cannot persist its own latch: in-memory latch, so a
  restart with a still-broken store fires once per boot (acceptable; stated).

## Implementation steps

1. Planner rules for each cause (≈ 60 lines) + message builders in
   `attention.ex`.

## Non-happy paths

Flapping inputs: `inputs_unavailable` uses the 2× grace so one late poll does
not alert.

## Compatibility and rollout

No config.

## Verification

| Test (`src/test/aiur/build_queue/attention_causes_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "AC3: prerequisite in agent:error with two dependents → one alert naming both" | one event; `blocked == ["11","12"]` | the cause rule |
| "AC3: restart does not re-fire" | zero events after restart | latch (C5-T01) — named regression guard here |
| "AC3: clearing the error resolves it" | one `.resolved` | resolve rule |
| "inputs_unavailable waits for the grace" | none at 1×, one at 2× | grace |
| "store_unavailable fires once per boot" | one | in-memory latch |

Mutation check: emit per dependent instead of per prerequisite → test 1 sees
two events.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue/attention_causes_test.exs
```

## Completion and handoff

- [ ] AC3 green; every cause wired.
- Docs: attention list in `concepts/ticket-lifecycle.md` queue section (C9-T02).
- Dependents: C9-T03.

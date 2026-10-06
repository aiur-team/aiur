---
ticket_id: MP-E1-C7-T02
feature_id: MP-E1
chunk_id: MP-E1-C7
bucket: 2-platform
title: Queue progress producer
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C7-T01, MP-E1-C3-T03]
prior_units: [U6]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 contract 4.1]
size_owner: n/a (build_queue files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C7-T02 — Queue scopes feed `Aiur.BuildProgress`

> **Plan refresh (wave 0).** `build_queue/` → `Aiur.BuildProgress` is a call to
> a neutral module (not orchestration, not GitHub), allowed by the seam rules.

## Identity and outcome

- Bucket 2, MP-E1, C7, T02.
- **User value:** a list queue (no Build Order) also reports progress and
  milestones.
- **Deliverable:** `build_queue/progress.ex` (PROPOSED) computing the fact per
  queue after each reconcile and calling `BuildProgress.put_fact/1`; the
  read model's `queues[].progress` uses the same function.

## Dependencies and blockers

- DESIGN-E1, C7-T01, C3-T03.

## Verified starting point (`45a290e3`)

Contract §4.1: `percent = completed ÷ (total − removed) × 100`, rounded
**down**; `resolution` `resolved` when every item's lifecycle is known,
`partial` otherwise, `unresolved` when none is.

## Chosen design

- `completed` = items `completed`; `cancelled` count toward `total` but not
  `completed`; `removed` items leave the denominator.
- `generation` = the queue's `generation` field (C2-T01), bumped when a
  completed queue receives a new item.
- Freshness = the worst source freshness of the queue.
- Build Order-kind queues do **not** produce a queue fact (the build-order
  scope from C7-T03 already covers that root; avoids two milestones for one
  root).

## Implementation steps

1. `progress.ex` (≈ 40 lines); server call after reconcile.

## Non-happy paths

Empty queue → no fact (no 100% from 0/0).

## Compatibility and rollout

None.

## Verification

| Test (`src/test/aiur/build_queue/progress_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "2 of 3 completed → 66 (floor)" | 66 | floor (round gives 67) |
| "a removed item leaves the denominator" | 2/2 → 100 | removal rule |
| "empty queue produces no fact" | none | guard |
| "build_order-kind queue produces no queue fact" | none | kind guard |

Mutation check: use `round` → test 1 fails.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue/progress_test.exs
```

## Completion and handoff

- [ ] Producer wired. Docs: none beyond C7-T01.
- Dependents: C8-T01.

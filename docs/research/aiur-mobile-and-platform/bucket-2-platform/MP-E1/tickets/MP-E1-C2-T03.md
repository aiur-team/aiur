---
ticket_id: MP-E1-C2-T03
feature_id: MP-E1
chunk_id: MP-E1-C2
bucket: 2-platform
title: "Downstream counts and the start-order rank"
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C2-T01]
prior_units: [U2]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 F3, F6]
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C2-T03 — `Aiur.BuildQueue.Ordering`

> **Plan refresh (wave 0).** Pure code under `src/lib/aiur/build_queue/`
> (PROPOSED). It moves unchanged into the `build-queue` package after MP-R1
> (plan §10). It must not reference `Aiur.Orchestrator`, `Aiur.GitHub` or
> `Aiur.BuildOrder` (C1-T07, contract §8): graph helpers are reimplemented
> here, following the cited approaches, not called.

## Identity and outcome

- Bucket 2, MP-E1, C2, T03.
- **User value:** the ticket that unblocks the most open work starts first,
  then priority, then list position, then age (D3, OQ-1).
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/ordering.ex`:
  `downstream_open(edges, open_items) :: %{issue_id => non_neg_integer()}`,
  `rank(item, downstream, priority, created_at) :: tuple()` (for the read
  model and promotion order) and `hint(item, downstream) :: {integer(), non_neg_integer()}`
  (the `{-downstream_open, position}` pair written to `Hints`, C1-T05).

## Dependencies and blockers

- DESIGN-E1 **OQ-1** (position after priority, before age, recommended).
- C2-T01. Concurrent with C2-T02.

## Verified starting point (`45a290e3`)

- Closure approach: `build_order/dependency_chain.ex:27-49` (`reachable/2`,
  iterative walk, excludes the node itself). Nothing calls it and there is no
  count function (F6).
- Dispatcher key and priority rank: `orchestrator/dispatch_policy.ex:609-630`
  (`priority_rank/1` gives 1–4 for `priority:N`, else 5).

## Chosen design

- `downstream_open`: for each item, the size of the set reachable through
  `prerequisite → dependent` edges, counting only items that are open and not
  removed. Computed once per reconcile over the union graph (all queues;
  one-owner rule keeps an issue in one queue).
- `rank` = `{-downstream_open, priority_rank, position, created_at_unix_us, number}`;
  `priority_rank` is passed in (the queue must not call `DispatchPolicy`) and
  reproduces `dispatch_policy.ex:620-622`.
- Build Order items have no list position → `position = 0`.
- The `hint` pair is exactly the first and third element, so the dispatcher's
  key (C1-T05) and the queue's rank agree.

## Implementation steps

1. `ordering.ex` (≈ 60 lines).

## Non-happy paths

Cycles: items in a cycle get `downstream_open` computed with a visited set
(no infinite loop); they are `unknown` anyway (C2-T02).

## Compatibility and rollout

New pure module.

## Verification

| Test (`src/test/aiur/build_queue/ordering_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "A→B→C, A→D: A has 3, B has 1" | counts | the transitive walk (a direct-only count gives A=2) |
| "a closed dependent is not counted" | A drops by 1 | the open filter |
| "rank orders downstream, then priority, then position, then age" — 4 items | expected order | each key element |
| "hint equals {elem(rank,0), elem(rank,2)}" (property) | holds | the shared derivation |
| "a cycle terminates" | returns | the visited set |

Mutation check: count direct dependents only → test 1 fails; swap position and
age → test 3 fails.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue/
```

## Completion and handoff

- [ ] Ordering implemented with OQ-1 applied.
- Dependents: C2-T04, C3-T03 (writes hints), C6-T01 (rank explanation).

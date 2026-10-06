---
ticket_id: MP-E1-C7-T03
feature_id: MP-E1
chunk_id: MP-E1-C7
bucket: 2-platform
title: Build Order progress observer
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C7-T01]
prior_units: [U6]
prior_boundaries: [BO #30]
prior_features: [MP-N5]
prior_findings: [MP-E1 F6, RC-08]
size_owner: n/a (new file in build_order/)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C7-T03 — `Aiur.BuildOrder.ProgressObserver`

> **Plan refresh (wave 0).** RC-08 names MP-E1-C7 as the producer of
> `system.build_order.<root>.progress`. The observer lives in `build_order/`
> because it reads the Build Order catalog; it is not part of `build_queue/`.
> After MP-R1 it moves with the `build-orders` component, which also owns
> `Aiur.BuildProgress` (RC-40).

## Identity and outcome

- Bucket 2, MP-E1, C7, T03.
- **User value:** every Build Order root reports the same percent the
  `/build-orders` page shows, and its 25/50/75/100 milestones, whether or not a
  queue adopted it.
- **Deliverable:** PROPOSED `src/lib/aiur/build_order/progress_observer.ex`
  subscribing to the catalog and calling `BuildProgress.put_fact/1` per root.

## Dependencies and blockers

- DESIGN-E1, C7-T01.

## Verified starting point (`45a290e3`)

- `GraphProjection.subscribe_catalog/1` (`build_order/graph_projection.ex:110-113`);
  messages `{:graph_projection_generation | :graph_projection_health, %Snapshot{}}`
  (`:1506-1515`); `catalog/1` (`:43-44`) for the initial read.
- `%Catalog{entries: [RootSummary], provider}` (`build_order/catalog.ex:27-41`);
  `RootSummary.progress`, `progress_resolution`, `progress_resolved_count`
  (`root_summary.ex:6, 21-23`); computed with `round` over resolved members
  (`catalog_store.ex:125-150`).
- Provider health: `ProviderHealth.usable?/1` (`build_order/lifecycle.ex:47-51`).

## Chosen design

- Percent and resolution are taken **as is** from `RootSummary` (contract
  §4.1: not recomputed, so the page and the notification agree, even though
  the catalog rounds while queue facts floor).
- Freshness: `current` when the catalog provider is usable, else `stale`.
- **Generation:** stored per root in the BuildProgress latch file; starts at
  1; bumps when a root previously at 100 (latched) reports `< 100` with
  `resolution: :resolved` (reopened or a new member).
- Root identity → integer issue number for the topic.

## Implementation steps

1. Observer GenServer (≈ 70 lines); child after `GraphProjection`
   (`src/lib/aiur.ex:357`) under `recording?`.

## Non-happy paths

Projection down → no facts; existing facts age to `stale` (the read API shows
`observed_at`).

## Compatibility and rollout

New process; zero GitHub cost (the catalog is event-sourced,
`build_order/catalog_store.ex:1-21`).

## Verification

| Test (`src/test/aiur/build_order/progress_observer_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "a catalog generation with a root at 50% resolved puts a fact with percent 50" | fact in `BuildProgress.facts/1` | subscription handling |
| "unusable provider marks facts stale (no milestone)" | `freshness: :stale`; no event | the health mapping |
| "a root back below 100 after 100 starts generation 2" | generation 2 | generation rule |

Mutation check: recompute percent with floor → test 1 stays 50 but a 2/3 root
fixture differs (67 vs 66) — include that fixture so it fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_order/progress_observer_test.exs
```

## Completion and handoff

- [ ] Observer producing build-order facts.
- Docs: `concepts/build-orders.md` mentions progress milestones (C9-T02).
- Dependents: MP-N5.

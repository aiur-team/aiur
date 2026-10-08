---
ticket_id: MP-E1-C4-T02
feature_id: MP-E1
chunk_id: MP-E1-C4
bucket: 2-platform
title: Build Order source - adopt a root as an optional dependency input
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C4-T01, MP-E1-C3-T05]
prior_units: [U2]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 F6, F10]
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C4-T02 — `Aiur.BuildQueue.Sources.BuildOrder`

> **Plan refresh (wave 0).** This is the **only** module allowed to reference
> `Aiur.BuildOrder.*` (C1-T07; component map §4). After MP-R1 it is chosen at
> runtime when capability `build_orders` is present.

## Identity and outcome

- Bucket 2, MP-E1, C4, T02.
- **User value:** `aiur queue add --build-order <root>` keeps a whole Build
  Order flowing, phase by phase, without the Executor promoting each wave.
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/sources/build_order.ex`
  implementing `Source`; `adopt(root)` server call; DESIGN-E1 OQ-7 behaviour:
  adopting a root whose blocked members already carry `agent:todo` withdraws
  todo from the unclaimed ones through the C3-T05 protocol.

## Dependencies and blockers

- DESIGN-E1 (**OQ-7**), C4-T01 (behaviour), C3-T05 (withdrawal).

## Verified starting point (`45a290e3`)

- `build_order/graph_projection.ex:46-59` `selected/2`, `demand/2` →
  `%Snapshot{data: %SelectedRoot{root, members, provider}}`
  (`build_order/selected_root.ex:8-16`); `:75-78` `refresh/2` (async,
  coalesced); `:115-118` `subscribe_selected/2`; broadcasts
  `{:graph_projection_generation | :graph_projection_health, snapshot}`
  (`:1506-1515`).
- `build_order/dependency.ex:6-24`: `kind :native|:external|:unknown`,
  `direction: :blocker_to_blocked`, `blocker_identity`, `blocked_identity`.
- Health: `build_order/lifecycle.ex:47-51` `ProviderHealth.usable?/1`;
  unusable → every edge `:unknown` (`edge_state.ex:9-11`).
- Per-root graphs held ≤ `graph_max_selected_roots` (32,
  `config/schema/build_order.ex:39`).
- Today members are pre-labelled `agent:todo` at creation
  (`.claude/skills/aiur-build/SKILL.md:231-236`, F10).

## Chosen design

- `adopt(root)`: `GraphProjection.demand/2` (free; registers interest) then
  `subscribe_selected/2`; on each generation message, rebuild items (open
  members, `position: 0`) and native edges; edges with `kind != :native` →
  `{:unknown, :external_edge}` for that dependent.
- Snapshot not `usable?` → `{:unavailable, :stale | :partial}`; the server
  treats every item of that queue as `unknown` (no writes) and reports the
  source freshness in the read model (`sources["build_order:<root>"]`).
- Member change hint (webhook/ResourceStore) → `GraphProjection.refresh/2`
  at most once per `reconcile_interval_seconds` per root.
- **OQ-7 adoption:** members that are not `ready` and carry `todo` with no
  claim go through `begin_withdraw`; claimed ones are left alone.
- One-owner rule applies: a member already in another queue is skipped with a
  per-member refusal in the result.
- More than 32 adopted roots → refused (`{:error, :too_many_roots}`).

## Implementation steps

1. Source module (≈ 120 lines) + `adopt/1`, `unadopt/1` server calls.
2. Capability flag `build_queue.build_order_source` in the read model.

## Non-happy paths

- GraphProjection not running → `{:unavailable, :projection_down}`; list
  queues unaffected (test with the module absent).
- Root closed or deleted → queue shows `completed`/`unknown`; no writes.

## Compatibility and rollout

Optional input; no config.

## Verification

| Test (`src/test/aiur/build_queue/build_order_source_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "stale snapshot built from real ProviderHealth values yields unavailable and no writes" | `{:unavailable, :stale}`; zero tracker calls | the usable? check |
| "native edges map to queue edges" | edges `{blocker, blocked, :build_order}` | mapping |
| "external edge → dependent unknown" | `{:unknown, :external_edge}` | the kind check |
| "OQ-7: adopting a root withdraws todo from an unclaimed blocked member, not from a claimed one" | one remove call | the adoption step |
| "ExecutorList works with the BuildOrder source unavailable" | list items promoted | source isolation |

Mutation check: treat stale as usable → test 1 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/build_order_source_test.exs
```

## Completion and handoff

- [ ] Adoption, refresh, health → unknown, OQ-7 withdrawal.
- Docs: `concepts/build-orders.md` "Queueing a Build Order" (C9-T02) and the
  `--build-order` flag (C6-T02).
- Dependents: C6-T02, C7-T03 (independent), C9-T01.

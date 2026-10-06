---
ticket_id: MP-N3-C1-T02
feature_id: MP-N3
chunk_id: MP-N3-C1
bucket: 3-mobile-watch
title: "Summary fields agents.active, agents.capacity and fleet.globally_paused from the snapshot read model"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C1-T01]
prior_units: []
prior_boundaries: [PRJ, ORC]
prior_features: []
prior_findings: []
size_owner: "n/a (new provider module)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C1-T02 — Agents and pause facts

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C1.
- **User value:** the phone row shows how many agents are running, and shows "paused" instead of
  a misleading "0 active" when the fleet is globally paused.
- **Deliverable:** provider `Aiur.InstanceSummary.Fleet.facts/1` (PROPOSED) filling
  `agents.active`, `agents.capacity` and `fleet.globally_paused` with the same semantics the
  dashboard uses.
- **Non-goals:** retrying/idle counts, per-agent detail (not in the summary).

## Dependencies and blockers

DESIGN-N3; MP-N3-C1-T01 (envelope). Concurrent with C1-T03..T05.

## Verified starting point (base `45a290e3`)

- `Aiur.Orchestrator.dashboard_snapshot/2` (`src/lib/aiur/orchestrator.ex:683-684`) delegates
  to `SnapshotStore.read/2`, which reads `:persistent_term` (`orchestrator/snapshot_store.ex:5-7,351`)
  and returns `{:current | :stale, snapshot, freshness}`, `:snapshot_unpublished` or
  `:orchestrator_unavailable` (`:68-73,384-388`). **RQ-N3-1 resolved:** the read does not join the
  Orchestrator mailbox, so its cost is a `persistent_term` lookup plus a liveness check; the
  summary passes a 300 ms timeout anyway.
- Dashboard mapping to reuse: `Presenter.snapshot_payload/2` (`src/lib/aiur_web/presenter.ex:37-58`):
  `running: length(snapshot.running)`, `capacity`, `globally_paused` (`:39`).
- The dashboard deliberately does not alarm on `:snapshot_unpublished` after a restart
  (`operator_control_center/overview.ex:136-142`).

## Chosen design

| Snapshot result | `agents.active` | `fleet.globally_paused` |
|---|---|---|
| `{:current, s, f}` | `available`, `length(s.running)`, `freshness: :current` | `available`, `s.globally_paused == true` |
| `{:stale, s, f}` | `available`, value, `freshness: :stale`, `age_ms` from `f` | same with `:stale` |
| `:snapshot_unpublished` | `unavailable`, reason `"starting"` | `unavailable`, `"starting"` |
| `:orchestrator_unavailable` | `unavailable`, reason `"orchestrator_unavailable"` | same |
| anything else | `unknown` | `unknown` |

`agents.capacity`: `available` with the snapshot's `capacity` max when it is an integer, else
`unavailable` reason `"capacity_unknown"`. The read uses `Presenter`'s public helper if one is
extracted; otherwise it reads `snapshot.running` directly (the struct is the read model's
public shape). The `age_ms` field is computed from the freshness map, never from the phone clock.

## Implementation steps

1. `src/lib/aiur/instance_summary/fleet.ex` (PROPOSED), with `snapshot_fun` injectable (default
   `&Aiur.Orchestrator.dashboard_snapshot(Aiur.Orchestrator, &1)`).
2. Register as the `agents`/`fleet` provider in `InstanceSummary`. About 70 lines.

## Non-happy paths

Restart (`starting`), Orchestrator down, stale snapshot (value kept, freshness stale), unexpected
return (`unknown`). Never 0 for an unavailable read.

## Compatibility and rollout

Read-only; no config. Plan refresh: after MP-R1-C9 the Orchestrator read API may move; keep the
injected function as the seam.

## Verification

`src/test/aiur/instance_summary/fleet_test.exs` (fake snapshot functions only):

1. `"current snapshot with 3 running yields active 3"`.
2. `"stale snapshot keeps the value and marks freshness stale with age_ms"`. *Fails without:* the stale clause.
3. `"snapshot_unpublished yields unavailable starting, not 0"`. Mutation: map it to
   `Fact.available(0)` → fails.
4. `"orchestrator_unavailable yields unavailable with that reason"`.
5. `"globally paused snapshot yields globally_paused true"`.
6. `"unexpected return yields unknown"`. Mutation: replace the fallback with `:unavailable` → fails.

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/instance_summary/fleet_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation checks recorded. Docs: none (internal). Dependents: MP-N3-C2-T01.

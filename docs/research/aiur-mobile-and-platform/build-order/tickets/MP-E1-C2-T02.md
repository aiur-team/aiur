---
ticket_id: MP-E1-C2-T02
feature_id: MP-E1
chunk_id: MP-E1-C2
bucket: 2-platform
title: "Prerequisite verdicts and item readiness"
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C2-T01]
prior_units: [U2]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 F3, F6, F7]
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C2-T02 — `Aiur.BuildQueue.Readiness`

> **Plan refresh (wave 0).** Pure code under `src/lib/aiur/build_queue/`
> (PROPOSED). It moves unchanged into the `build-queue` package after MP-R1
> (plan §10). It must not reference `Aiur.Orchestrator`, `Aiur.GitHub` or
> `Aiur.BuildOrder` (C1-T07, contract §8): graph helpers are reimplemented
> here, following the cited approaches, not called.

## Identity and outcome

- Bucket 2, MP-E1, C2, T02.
- **User value:** a dependent starts only after its prerequisites truly
  completed; a failed prerequisite holds it instead of silently releasing or
  silently holding it (D6, plan §2 gap 2).
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/readiness.ex`:
  `edge_verdict(observation, opts) :: :satisfied | :pending | {:failed, cause} | {:unknown, cause}`
  and `item_verdict([edge_verdict]) :: :ready | :waiting | {:failed, causes} | {:unknown, causes}`,
  plus `cyclic_items(edges) :: MapSet.t()`.
- **Non-goals:** observation I/O (C4), the merged-but-open timer (C4-T06 feeds
  a `:merged_open` flag in).

## Dependencies and blockers

- DESIGN-E1 **OQ-2** (does `not_planned` fail?) — implemented as
  `opts[:not_planned]` = `:fail` (recommended) or `:satisfy`; the chosen
  default is the DESIGN-E1 answer. OQ-3 is handled in C2-T04.
- C2-T01. Concurrent with C2-T03.

## Verified starting point (`45a290e3`)

- Contract §2.1 table and §2.2 order (unknown > failed > waiting > ready).
- Today's analogues: `build_order/edge_state.ex:9-22` (not_planned →
  `:terminal_unsatisfied`; unusable health → `:unknown`) and `:31-41`
  ordering cyclic > unknown > terminal_unsatisfied > blocking > ready.
- The dispatcher releases a dependent when its blocker is closed for any
  reason (`orchestrator/dispatch_policy.ex:1000-1008`, F3) — the queue is
  deliberately stricter.
- Cycle approach: SCC in `build_order/graph_analysis.ex:120-187`.

## Chosen design

| Observation of the prerequisite | Verdict |
| --- | --- |
| `open?: false`, `state_reason: "completed"` | `:satisfied` |
| `open?: false`, `"not_planned"` | `{:failed, :not_planned}` (or `:satisfied` per OQ-2) |
| `open?: false`, `"duplicate"` / nil / other | `{:unknown, :closed_reason}` |
| `open?: true`, label `<prefix>:error` | `{:failed, :agent_error}` |
| `open?: true`, `pr: :closed_unmerged` | `{:failed, :pr_closed_unmerged}` |
| `open?: true`, otherwise | `:pending` |
| `open?: :unknown`, or observation older than `max_age_ms`, or nil | `{:unknown, :stale}` |
| edge in a cycle | `{:unknown, :cyclic}` |

`item_verdict/1` takes the first match in contract §2.2 order and collects
all causes of that class. An item with no edges is `:ready`. Cycle detection:
iterative Tarjan over `Edge` list, bounded at 1 000 nodes (larger graph →
every item `{:unknown, :graph_too_large}`).

## Implementation steps

1. `readiness.ex` with the table above as function clauses.
2. `cyclic_items/1` (≈ 40 lines).

## Non-happy paths

Stale, missing and cyclic data are all `unknown`, never `ready` or
`waiting` (contract §1 rule 4). Label prefix comes from opts, not config.

## Compatibility and rollout

New pure module.

## Verification

| Test (`src/test/aiur/build_queue/readiness_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| one case per table row | verdict as in the table | each clause |
| "one failed and one pending prerequisite → failed" | `{:failed, [:agent_error]}` | the §2.2 order |
| "unknown beats failed" | `{:unknown, _}` | the order |
| "a 3-cycle makes all three unknown" | `{:unknown, [:cyclic]}` each | `cyclic_items/1` |
| "a stale observation is never satisfied" — closed/completed but `observed_at_ms` too old | `{:unknown, :stale}` | the age check |
| property: "verdict never ready when any edge is not satisfied" | holds for generated inputs | the AND rule |

Mutation check: map `not_planned` to `:satisfied` with default opts → its row
fails; drop the age check → the stale test fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/
```

## Completion and handoff

- [ ] Contract §2.1/§2.2 implemented with OQ-2 applied.
- Dependents: C2-T04, C4-T03..T05.

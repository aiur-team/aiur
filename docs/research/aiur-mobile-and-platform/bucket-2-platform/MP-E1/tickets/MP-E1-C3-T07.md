---
ticket_id: MP-E1-C3-T07
feature_id: MP-E1
chunk_id: MP-E1-C3
bucket: 2-platform
title: Restart recovery and marker-based rebuild
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T04]
prior_units: [U3, U6]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 F4, F9]
size_owner: n/a (build_queue files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C3-T07 — Converge after a crash; rebuild from markers

> **Plan refresh (wave 0).** Uses only `build_queue/` modules and the tracker
> facade; moves unchanged after MP-R1. U3 is cited for ordering: the queue is
> level-triggered and needs no event cursor (contract §6 E-A5).

## Identity and outcome

- Bucket 2, MP-E1, C3, T07. Plan §6 Restart recovery.
- **User value:** a daemon crash or restart never duplicates a label or
  strands a queue item (AC11); a lost store is recoverable from GitHub.
- **Deliverable:** boot-time intent resolution in the server, and
  `Aiur.BuildQueue.recover/0` (the core of `aiur queue recover`, C6-T03).

## Dependencies and blockers

- DESIGN-E1, C3-T04.

## Verified starting point (`45a290e3`)

- On restart `running`/`claimed` start empty and `StartupClaimReconciler`
  moves orphaned `in-progress` back to `todo`
  (`orchestrator/startup_claim_reconciler.ex:112, 149-166`, F4).
- Store fail-closed (C3-T02); observations come from the tracker
  (`open_issue_labels/1`, C1-T03).

## Chosen design

**Boot:** load store → for each intent with no outcome, wait for the first
observation (no writes before it), then set the outcome from what is observed
(`todo` present → `:ok`; absent → `:not_applied`) → plan normally. Because the
planner only promotes items whose `todo` is absent, a write that happened
before the crash is never repeated.

**Recover** (store missing or corrupt): rename a corrupt file
(`queue.json.corrupt-<unix>`); read `open_issue_labels/1`; every open issue
carrying the marker becomes an item of one new list queue `recovered`, no
edges, all `held: :operator`, ordered by issue number; save; status
`running`. The operator re-orders and releases (DESIGN-E1 copy).

## Implementation steps

1. Server init: `:awaiting_first_observation` phase.
2. `recover/0` in the facade + server call.

## Non-happy paths

- No observation available at boot (snapshot stale) → stay in the awaiting
  phase; status `running` with `freshness: unknown`; no writes.
- Recover with no marker-carrying issues → empty queue, no error.

## Compatibility and rollout

No config.

## Verification

| Test (`src/test/aiur/build_queue/recovery_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "AC11: kill after the promote call returns, before the outcome is saved; restart → exactly one promote call overall" (fake tracker counts across both server lifetimes) | 1 call; item `promoted` | outcome-from-observation |
| "intent without outcome and todo absent → not_applied, then promoted once" | 1 call after restart | same |
| "no writes before the first observation after boot" | zero calls while snapshot is `:none` | the awaiting phase |
| "recover rebuilds a held list from marker-carrying open issues" | items = marker issues, all held, no edges | `recover/0` |

Mutation check: skip the awaiting phase → test 3 fails; re-run unfinished
intents blindly → test 1 sees 2 calls.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue/recovery_test.exs
```

## Completion and handoff

- [ ] AC11 green; `recover/0` ready for the CLI.
- Docs: with C6-T03.
- Dependents: C6-T03.

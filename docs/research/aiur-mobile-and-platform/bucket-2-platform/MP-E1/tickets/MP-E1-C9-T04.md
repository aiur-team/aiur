---
ticket_id: MP-E1-C9-T04
feature_id: MP-E1
chunk_id: MP-E1-C9
bucket: 2-platform
title: Measure queue GitHub cost and census Build Order sizes (instrumentation, no saving claimed)
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C9-T03]
prior_units: [U9]
prior_boundaries: []
prior_features: []
prior_findings: [MP-E1 F11, RQ-9]
size_owner: n/a (measurement)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C9-T04 — What the queue costs, measured

> **Plan refresh (wave 0).** Follows AGENTS.md "A claimed saving must be
> measured": this ticket **claims no saving**; it makes the queue's cost
> visible and settles RQ-9 (pacing defaults) with a census.

## Identity and outcome

- Bucket 2, MP-E1, C9, T04. Settles RQ-9.
- **Deliverable:** a PR-body (or `docs/research` note in the PR) with:
  1. label writes and observation reads per hour attributed to the queue
     (`build_queue_observe` caller, label POST/DELETE) from `aiur github-cost`
     during the C9-T03 run and during one ordinary Build Order run;
  2. a census of recent Build Order sizes (members per root) and the peak
     number of items that became ready in one reconcile;
  3. a decision: keep `max_writes_per_minute: 20` or change it, with the
     numbers.

## Dependencies and blockers

- DESIGN-E1, C9-T03. Needs the live daemon (not available to Phase C
  research, which is why RQ-9 is open).

## Verified starting point (`45a290e3`)

- `aiur github-cost` per-caller points and rate; read
  `website/docs-app/apis/github.md` "Reading these numbers without fooling
  yourself" first (AGENTS.md).
- `aiur build-orders --json` lists roots and members (`build_orders_cli.ex`).
- GitHub secondary limit 80/min, 500/hour (F11).

## Chosen design

Measure twice and diff (memory "measure the rate, not the level"); quote the
census with date and size.

## Implementation steps

1. Run, record, write up. If the census shows a peak > 20 ready per reconcile,
   open a follow-up for the default.

## Non-happy paths

n/a — measurement. A missing caller attribution is a bug in C4-T04 (file it).

## Compatibility and rollout

n/a.

## Verification

The write-up contains: numbers with units and baselines, the command lines
used, the census date and population size, and the explicit statement "no
saving claimed".

## Completion and handoff

- [ ] Write-up in the PR; RQ-9 closed in `chunks.md`.
- Dependents: none.

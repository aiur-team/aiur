---
title: BQ-G4-3 Report redone and discarded optimistic work - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g4/brainstorm.md
execution: code
epic: aiur-team/aiur#3755
code_baseline: origin/main 0e5b8d0de
---

# BQ-G4-3 Report redone and discarded optimistic work - Plan

## Goal Capsule

- **Objective:** Count, per optimistic dependent and per start trigger, the
  blocker pushes absorbed, conflicting integrations, parks, redo and discard
  outcomes, head start, and wasted agent time; show them in
  `analytics/run-summary`, `analytics/build-report`, and the Build Order page's
  Analytics pane.
- **Product authority:** brainstorm R10-R14, D5, D6.
- **Product Contract preservation:** Product Contract unchanged.

## Problem Frame

Run telemetry already flows one way: `Aiur.RunTelemetry.Lifecycle.record/6`
(`src/lib/aiur/run_telemetry/lifecycle.ex`) -> NDJSON -> Python reducer
(`analytics/lib/analytics/reduce.py`, `_lifecycle_event`, `_reduce_tickets`) and
Elixir `Aiur.RunTelemetry.Dataset` -> `analytics/build-report`
(`analytics/lib/analytics/build_report.py`, `render.py`) and the Build Order
Analytics pane (`src/lib/aiur_web/operator_control_center/analytics/presenter.ex`
`compute_kpis/4`, tiles in
`src/lib/aiur_web/components/operator_control_center/build_order_analytics.ex`
`kpi_items/2`). No event says a start was optimistic or what it cost.

## Requirements

Carried from origin: R10 (per-dependent counters), R11 (head start and waste),
R12 (lifecycle telemetry is the report path), R13 (group by trigger), R14
(one KPI tile, gantt marks the park).

## Key Technical Decisions

- **KTD1. New lifecycle events, all `point`:** `optimistic_start` (BQ-G4-1),
  `blocker_integrate` (metadata `blocker`, `outcome`: `clean`|`conflict`,
  `non_ff`: bool), `optimistic_park` (`blocker`, `cause`),
  `optimistic_resume`, `optimistic_outcome` (`outcome`, `head_start_ms`,
  `waste_ms`, `start_trigger`). Add to `@events` and `@metadata_fields`.
- **KTD2. Source of `blocker_integrate`.** Primary: the agent emits
  `ticket.<self>.optimistic.integrated` `{blocker, sha, conflict}` after each
  blocker integration (G2 skill section; G3 restack uses the same event). The
  orchestrator subscribes to `ticket.*.optimistic.integrated`, bumps ledger
  counters, and records the lifecycle point. Fallback when the agent does not
  emit: each blocker `branch.push` observed for an open record bumps
  `pushes_absorbed`. Non-fast-forward is reported by the agent (`non_ff` in
  the integrated event), because the ls-remote push source carries only the
  new SHA and cannot tell a force-push from a fast-forward. Reports label agent-reported conflicts separately from
  push counts so a missing agent emit reads as "unknown", not zero.
- **KTD3. Head start and waste.** On the dependent's outcome:
  `head_start_ms = max(0, min(blocker merged_at) - started_at)` across
  optimistic blockers, only when the dependent merged; `waste_ms` = active
  agent time of the attempt(s) between `optimistic_start` and the park, only
  when the outcome is `discarded`. Active time comes from the ledger's
  attempt ids joined to existing `implement` intervals by the reducer, not
  from wall clock.
- **KTD4. No run-summary schema bump.** Per-ticket data goes inside the
  free-form `tickets` object (`tickets.<id>.optimistic`), which
  `schema/run-summary.v1.json` already allows. The cross-ticket rollup is
  computed by `render.py` at report time, not stored at top level (top level
  is `additionalProperties: false`).
- **KTD5. Page tile.** One KPI tile "Optimistic starts": value N; sub-line
  "R redone - D discarded - Xh head start". Tone `block` when D > 0. Hidden
  when N = 0 so non-optimistic builds look unchanged. Gantt: the existing
  `ticket_status/2` gains `:optimistic_parked` from an `optimistic_park`
  interval with no later `optimistic_resume`.
- **KTD6. Label it head start.** Never "time saved" (origin D6).

## Implementation Units

### U1. Lifecycle events and orchestrator emitters

**Goal:** Emit the four new events from the right owners.
**Requirements:** R10, R12, KTD1, KTD2.
**Dependencies:** BQ-G4-1 (ledger, `optimistic_start`); BQ-G4-2 for
`optimistic_park` call site.
**Files:** `src/lib/aiur/run_telemetry/lifecycle.ex`,
`src/lib/aiur/orchestrator/lifecycle.ex` (`@orchestrator_topics` adds
`ticket.*.optimistic.integrated`), `src/lib/aiur/orchestrator/event_topics.ex`,
`src/lib/aiur/orchestrator/push_routing.ex` (`record_blocker_branch_push/3`
bumps `pushes_absorbed` for ledgered dependents of that blocker),
`src/lib/aiur/orchestrator/optimistic_ledger.ex` (outcome computation, KTD3),
`src/test/aiur/run_telemetry/lifecycle_test.exs`,
`src/test/aiur/orchestrator/push_routing_test.exs`,
`src/test/aiur/orchestrator/optimistic_ledger_test.exs`.
**Approach:** Agent-scoped topic validation: only accept
`ticket.<self>.optimistic.integrated` from the dependent's own session (reuse
the emit authorization the agent topic namespace already enforces).
**Test scenarios:**
- Agent emits integrated `{conflict: true}` -> ledger
  `integrations_conflict` +1 and one `blocker_integrate` point with
  `outcome: conflict`.
- Blocker push for a blocker with two ledgered dependents -> both
  `pushes_absorbed` +1.
- Integrated event with `non_ff: true` -> `non_ff_pushes` +1.
- Dependent merged, blocker merged 3 h after the dependent's start ->
  `optimistic_outcome` with `head_start_ms` 3 h.
- Blocker merged before start (should not happen) -> head start 0.
- Discarded after 2 h of `implement` intervals -> `waste_ms` 2 h.
- Integrated event for a ticket with no ledger record -> ignored, no telemetry.
**Verification:** tests pass.

### U2. Python reducer and reports

**Goal:** Reduce the events per ticket and print them.
**Requirements:** R10, R11, R13, KTD4, KTD6.
**Dependencies:** U1 (event names).
**Files:** `analytics/lib/analytics/reduce.py` (`_lifecycle_event` copies
`blocker`, `outcome`, `non_ff`, `start_trigger`, `head_start_ms`, `waste_ms`;
`_reduce_tickets` adds `optimistic`), `analytics/lib/analytics/render.py`
(build-report "Optimistic start" section grouped by trigger; run-summary one
line), `analytics/tests/test_reduce.py`, `analytics/tests/test_render.py`,
`analytics/tests/fixtures/` (new optimistic fixture), `analytics/README.md`.
**Approach:** Per-ticket `optimistic` block: `{start_trigger, blockers,
pushes_absorbed, integrations: {clean, conflict, unknown}, non_ff, parks,
resumes, outcome, head_start_ms, waste_ms}`. Rollup in render: by trigger:
starts, merged, redone, discarded, discard rate, total head start, total waste.
**Test scenarios:**
- Fixture with three optimistic dependents (merged, merged_after_redo,
  discarded) -> per-ticket blocks and rollup match hand counts.
- Ticket with `optimistic_start` but no outcome -> outcome `open`, excluded
  from rates.
- Two triggers in one build -> two rollup rows.
- No optimistic events -> section omitted (existing report text byte-identical).
- `--json` includes the rollup.
**Verification:** `PYTHONPATH=analytics/lib python3 -m unittest` green.

### U3. Elixir dataset and Build Order page tile

**Goal:** Same numbers on the Build Order page for the current session.
**Requirements:** R14, KTD5.
**Dependencies:** U1.
**Files:** `src/lib/aiur/run_telemetry/dataset.ex` (`lifecycle_event/1`
carries the new fields), `src/lib/aiur_web/operator_control_center/analytics/presenter.ex`
(`compute_kpis/4` adds `optimistic: %{starts, redone, discarded, head_start_ms}`;
`ticket_status/2` adds `:optimistic_parked`),
`src/lib/aiur_web/components/operator_control_center/build_order_analytics.ex`
(`kpi_items/2` tile), `src/lib/aiur_web/operator_control_center/analytics/charts.ex`
(status colour for `:optimistic_parked`),
`src/test/aiur/run_telemetry/dataset_test.exs`,
`src/test/aiur_web/operator_control_center/analytics/presenter_test.exs`,
`src/test/aiur_web/operator_control_center/build_order_analytics_test.exs`.
**Test scenarios:**
- Scope with 2 optimistic starts, 1 redone, 1 discarded -> tile "2", sub-line
  "1 redone - 1 discarded - <h> head start", tone block.
- Scope with zero optimistic starts -> no tile; existing six tiles unchanged.
- Parked without resume -> gantt status `:optimistic_parked`; after resume ->
  `:active`.
- Copy check: no "saved" wording.
**Verification:** tests pass; a browser look at the Build Order page with the
fixture telemetry (`analytics_telemetry_file` pointed at the fixture) shows
the tile at desktop and phone widths.

## Scope Boundaries

- Out: automatic trigger tuning (Q3); feeding G5's share cap (later).
- Out: dollar cost of waste (cost-report can join later by ticket).

## Risks & Dependencies

- Agent emit compliance (G2 skill). Mitigated by the push-count fallback and
  the explicit `unknown` integration bucket.
- Telemetry disabled -> no report data; the ledger still holds counters, so a
  later `aiur` CLI view could read it (deferred).

## Documentation Plan

- `analytics/README.md`: build-report row mentions the optimistic section.
- `website/docs-app/concepts/build-orders.md`: "Measuring optimistic start"
  paragraph: what each number means, that head start is an upper bound, and
  how to compare triggers with `analytics/build-report <slug>`.

## Definition of Done

- U1-U3 tests pass (mix and Python); CI green on the head SHA.
- Fixture build-report prints the grouped optimistic section; the Build Order
  page shows the tile for a fixture with optimistic starts and hides it otherwise.

---
title: "EXP-X2-3: Ship the built-in delivery-speed metric pack - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/experiments/x2/brainstorm.md
date: 2026-10-09
ticket: EXP-X2-3
epic: aiur-team/aiur#3774
---

# EXP-X2-3: Ship the built-in delivery-speed metric pack - Plan

Product Contract: [brainstorm.md](brainstorm.md) (R6, R11, R12, KD2). Product Contract unchanged.
Depends on EXP-X2-2 ([plan-metric-packs.md](plan-metric-packs.md)). Cross-area: several metrics need X1 capture (marked below).

## Summary

Implement `Aiur.Experiments.Packs.DeliverySpeed`, the built-in pack that turns Aiur's own run telemetry into per-unit observations for the operator's four metric groups, all enabled by default.
It is a normal pack behind the `MetricPack` behaviour, so a consumer repo that does not care about it can disable it (`experiments.disabled_packs`), and nothing else in the component knows about tickets or PRs.

---

## Key technical decisions

- **KTD1. One pack, four groups** (session-settled: operator, "all on by default"; the brief names it "delivery speed"). Pack id `delivery-speed`; metric `group` ∈ `flow`, `review`, `throughput`, `cost_quality`.
- **KTD2. Data comes through one adapter.** `Aiur.Experiments.Packs.DeliverySpeed.TelemetrySource` is the only module that reads `Aiur.RunTelemetry` (`Dataset.build/2` on the live stream plus `Summaries.load_prior_datasets/1` for materialized prior boots), and `Aiur.UsageAggregate.query/1` for cost (optional `accounting` dependency). It normalises them to one `TicketRecord` shape: `ticket, complexity, cohort, events[{event, boundary, at}], intervals`. When X1 changes field names, only this adapter changes.
- **KTD3. Unit and assignment time.** Ticket metrics: unit `ticket:<n>`, `at` = first `dispatch` time (assignment by start), `finished_at` = metric end event. Period metrics (`merged_per_hour`, `idle_slot_hours`, `agents_vs_cap`): unit `hour:<iso hour>`, `at` = bucket start. Attributes: the ticket's `cohort` map plus `complexity`, so stratification (R6) and A/B predicates work on every ticket metric.
- **KTD4. Missing capture reports `not_captured`, not zero** (R11, R12). Each metric declares `requires`; the adapter reports which facts the data actually holds (e.g. `pr_opened_source_time` only after X1 fixes `reduce.py:366-368` and the presenter read gap).
- **KTD5. Reattempts.** A ticket dispatched more than once in a window is one unit; `start` is the first dispatch, `rework_time` sums every `rework_start → next pr_opened|pr_merged` span. Tickets never merged contribute to `start_to_pr_open` if a PR opened, and are excluded from merge metrics (counted as `filtered`).

## Metric table

`X1` = needs a capture fact X1 delivers; until then the metric reports `not_captured`.

| Group | Metric id | Unit | Better | Definition | Needs |
|---|---|---|---|---|---|
| flow | `start_to_pr_open` | ticket | lower | first dispatch → first pr_opened | X1 (true PR-open time) |
| flow | `pr_open_to_merge` | ticket | lower | first pr_opened → pr_merged | X1 (same) |
| flow | `start_to_merge` | ticket | lower | first dispatch → pr_merged | — |
| flow | `blocker_merge_to_dependent_start` | ticket | lower | last blocker's pr_merged → dependent's first dispatch | X1 (`blocked_by` on dispatch) |
| flow | `gap_between_prs` | ticket | lower | per ticket in a Build Order or epic: its pr_merged − previous member's pr_merged | X1 (`epic`) |
| review | `pr_ready_to_first_review` | ticket | lower | pr_opened → first comment_received from a reviewer | X1 (review event source) |
| review | `review_rounds` | ticket | lower | count of review_pause boundaries before merge | — |
| review | `rework_time` | ticket | lower | Σ rework_start → next pr_opened/pr_merged | — |
| review | `ci_wait` | ticket | lower | Σ CI pending spans before merge | X1 (CI events) |
| throughput | `merged_per_hour` | hour | higher | pr_merged count per hour bucket while ≥1 agent is active | — |
| throughput | `agents_vs_cap` | hour | higher | mean running agents / configured cap per hour | — |
| throughput | `idle_slot_hours` | hour | lower | (cap − running) × hours while ready work existed | X1 (ready-queue depth) |
| throughput | `binding_gate` | hour | none | share of hour each gate (cap, load governor, budget, CI) held dispatch; reported per gate as `binding_gate.<gate>` observations | X1 (gate reason) |
| cost_quality | `spend_per_merged_ticket` | ticket | lower | provider spend (USD) attributed to the ticket | accounting |
| cost_quality | `tokens_per_merged_ticket` | ticket | lower | input + output tokens attributed to the ticket | accounting |
| cost_quality | `main_red_events` | day | lower | count of default-branch CI failures per day | X1 |
| cost_quality | `reverts` | day | lower | count of revert merges per day | X1 |

`binding_gate` is categorical; X4 treats it as proportions, so its `default_direction` is `none`.

---

## Implementation units

### U1. Telemetry source adapter

**Goal:** one normalised read of tickets and periods for a window.
**Requirements:** KTD2, KTD4.
**Dependencies:** EXP-X2-2.
**Files:** `src/lib/aiur/experiments/packs/delivery_speed/telemetry_source.ex`, `src/test/aiur/experiments/packs/delivery_speed/telemetry_source_test.exs`, `src/test/fixtures/experiments/telemetry/*.ndjson`.
**Approach:** windowed read: live dataset filtered by time plus prior-boot summaries overlapping the window; dedupe tickets across boots by ticket id (merge events, keep earliest dispatch). Reports `facts` present and `earliest_at` for coverage. Manifest: add `telemetry` and `accounting` to `experiments.optional`; the pack returns `unavailable/telemetry_disabled` when `observability.telemetry_enabled` is false.
**Patterns to follow:** `AiurWeb.OperatorControlCenter.Analytics.Presenter` prior-boot loading (`load_prior_datasets_with_state/1`).
**Test scenarios:** one ticket split across two boots (dispatch in boot A, merge in boot B) → one record with both events; window excluding boot B → no merge event; corrupt prior summary → skipped, `partial` coverage; telemetry disabled → `unavailable`.
**Verification:** fixture covers a restart mid-ticket.

### U2. Flow and review metrics

**Goal:** the ticket-unit metrics.
**Requirements:** R12, KTD3, KTD5.
**Dependencies:** U1.
**Files:** `src/lib/aiur/experiments/packs/delivery_speed.ex`, `src/lib/aiur/experiments/packs/delivery_speed/flow.ex`, `src/lib/aiur/experiments/packs/delivery_speed/review.ex`, `src/test/aiur/experiments/packs/delivery_speed/flow_test.exs`, `src/test/aiur/experiments/packs/delivery_speed/review_test.exs`, `src/config/config.exs` (register pack).
**Test scenarios:**
- `start_to_merge`: dispatch 10:00, merged 12:30 → 9,000,000 ms with `attrs.complexity` and cohort.
- Two dispatches (10:00, 11:00) → start is 10:00 (KTD5).
- Never merged → excluded, counted `filtered`.
- `review_rounds`: three review_pause starts → 3.
- `rework_time`: rework 11:00→11:20 and 12:00→12:10 → 30 min.
- `start_to_pr_open` on data without the X1 PR-open fact → coverage `not_captured`, no observations.
- `blocker_merge_to_dependent_start` with `blocked_by: [3763]` (X1 shape) and 3763 merged at 09:00, dependent dispatched 09:02 → 120,000 ms; without `blocked_by` facts → `not_captured`.
**Verification:** each metric has a fixture-driven test.

### U3. Throughput and cost/quality metrics

**Goal:** the period and cost metrics.
**Requirements:** R12.
**Dependencies:** U1.
**Files:** `src/lib/aiur/experiments/packs/delivery_speed/throughput.ex`, `src/lib/aiur/experiments/packs/delivery_speed/cost_quality.ex`, matching tests.
**Approach:** hour buckets from `max(window.start, earliest_at)`; an hour with no active agent is not a `merged_per_hour` observation (otherwise nights dilute the median). Cost from `UsageAggregate.query(%{ticket: n})`; when accounting is absent → `unavailable/accounting_absent`.
**Test scenarios:** 2 merges in hour 1, 0 in hour 2 with agents active, no agents in hour 3 → observations `[2, 0]`; cap 4 and 3 running all hour → `agents_vs_cap` 0.75; ticket with $1.20 usage → 1.2; accounting stub missing → `unavailable`; `main_red_events` without X1 facts → `not_captured`.

### U4. Docs

**Goal:** operators know what each metric means.
**Dependencies:** U2, U3.
**Files:** `website/docs-app/concepts/experiments.md` (metric table, `not_captured` meaning, how to disable the pack).
**Test expectation:** none -- documentation.

---

## Risks

| Risk | Mitigation |
|---|---|
| X1 field names differ from assumption A1 | Only `TelemetrySource` reads them; X1's plan is the authority, adapter follows. |
| Summaries missing for recent boots (dossier) | Live dataset covers the current boot; coverage reports gaps. |
| Night-time and paused-fleet hours skew period metrics | Buckets only count hours with active agents (U3). |
| Cost attribution lag (usage ledger compaction) | Cost metrics read at freeze time; the snapshot records `computed_at`. |

## Definition of done

All 17 metrics exist in `aiur experiments metrics`; metrics without their capture fact report `not_captured`; fixture tests per metric pass; disabling the pack removes it from the catalog.

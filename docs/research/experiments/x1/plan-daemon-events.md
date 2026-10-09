---
title: EXP-X1-3 Daemon metric events - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x1/brainstorm.md
ticket: EXP-X1-3
complexity: 2
---

# EXP-X1-3 Daemon metric events - Plan

## Summary

This plan adds the lifecycle events that only the daemon can see:

| Event | What it records | Metrics it feeds |
|---|---|---|
| `state_change` | Every observed ticket state transition, from any writer | CI wait, rework time, review rounds |
| `ci_result` | Terminal CI outcome per head SHA | CI wait, CI outcome |
| `pr_ready` | The live `pr.ready_for_review` anchor | PR ready time |
| `dependency_cleared` | A blocker became terminal, or was removed | Blocker clearance → dependent start |
| `ticket_usage` | Token and spend totals per ticket, at a terminal state | Spend and tokens per merged ticket |

It also samples the fleet's binding capacity constraint in the resource sampler.

## Problem Frame

- `rework_start` is emitted only for comment-driven rework (`src/lib/aiur/orchestrator/comment_wake.ex:1379-1385`). Human-review reverts (`src/lib/aiur/orchestrator/human_review.ex:176-200`) and Executor label edits leave no rework event.
- `ci-wait` is a ticket state (`src/lib/aiur/orchestrator/ci_lifecycle.ex:30`). Telemetry records neither when a ticket enters or leaves it nor the CI result. The terminal events `ticket.<t>.ci.{passed,failed}` are published (`ci_lifecycle.ex:337-341`), but the telemetry Writer subscribes to only four patterns (`src/lib/aiur/run_telemetry/writer.ex:32-37`).
- `ticket.<t>.pr.ready_for_review` is published (`src/lib/aiur/events/github_firehose.ex:421`, `src/lib/aiur/events/github_webhook/normalizer.ex:646`), but `Lifecycle.external_topic/1` does not map it (`src/lib/aiur/run_telemetry/lifecycle.ex:469-477`).
- Blocker changes are seen in `IssueSync.emit_dependency_transition_events/3` (`src/lib/aiur/orchestrator/issue_sync.ex:1166-1204`), but they are not recorded.
- The observed state diff lives in `emit_task_state_transition_alert/3` (`issue_sync.ex:1215-1259`, called at about line 855). That is the one place that sees transitions from every writer.
- Usage per ticket is queryable: `Aiur.UsageAggregate.query/1` takes a ticket scope (`src/lib/aiur/usage_aggregate/key.ex:66`). It is not in telemetry, and usage compaction retires raw rows.
- The sampler records the host-pressure admission signal only (`src/lib/aiur/run_telemetry/sampler.ex:343-367`). The binding constraint (`Aiur.Orchestrator.CapacityBinding.binding/2`, kinds `:config_cap`, `:envelope`, `:admission`, `:ticket_supply` and others) is not sampled.

Requirements: R1, R6, R7. Decision KD5.

## Key Technical Decisions

- **KTD1. One observed `state_change` event instead of per-writer events.** It is emitted from the IssueSync state diff with `from_state` and `to_state` (normalized slugs) and `cause: :observed`. Reason: it covers every writer (comment wake, human-review revert, Executor `gh` edits, build queue), so review rounds and rework time no longer depend on which code path wrote the label. Ticket writers that already emit events (such as `rework_start`) keep them.
- **KTD2. CI wait is derived, not separately emitted.** CI wait is the time between a `state_change` into `ci-wait` and the next `state_change` out of it (or the `ci_result`). `ci_result` comes from the Writer subscribing to `ticket.*.ci.passed` and `ticket.*.ci.failed`, mapped in `Lifecycle.external_anchor/1`, with `outcome`, `pr_number` and `head_sha` (the SHA as a short identifier, which is not free text).
- **KTD3. `pr_ready`.** It is a new external mapping for `pr.ready_for_review`, and it is added to the Writer's subscriptions and to `@carried_point_events`. GitHub facts (EXP-X1-4) remain the source of truth. This live event lets the current boot show it without waiting for facts.
- **KTD4. `dependency_cleared`.** It is a point on the dependent ticket with `blocker` (identifier) and `cause` (`:removed` or `:terminal`). Reason: with the dispatch `blockers` list (EXP-X1-2), the ledger can compute both "blocker merged → dependent start" and "dependency cleared → dependent start".
- **KTD5. `ticket_usage` at terminal.** When the Writer records `pr_merged` for a ticket, or IssueSync observes `done` or `closed`, the daemon queries `UsageAggregate.query(%{ticket: t})`. It records totals: input, output and cached tokens, and provider-reported cost amount and currency when available, plus a `coverage` class. The query is off the dispatch path (Task under the telemetry supervisor), and it fails open.
- **KTD6. `fleet_binding_kind`.** It is added to the sampler's fleet fields from `CapacityBinding.binding(capacity, polling)`, as a kind string only. It is also added to `RESOURCE_EVIDENCE` in `analytics/lib/analytics/reduce.py:52-60`.

## Implementation Units

### U1. Lifecycle registry and external mappings

**Goal:** New event names, metadata fields and topic mappings.
**Files:** `src/lib/aiur/run_telemetry/lifecycle.ex` (`@events`, `@metadata_fields`: `from_state`, `to_state`, `blocker`, `head_sha`, `input_tokens`, `output_tokens`, `cached_tokens`, `cost_amount`, `cost_currency`, `coverage`; `external_topic/1` regex adds `pr\.ready_for_review|ci\.passed|ci\.failed`; `external_event/1` and `external_metadata/3` for CI), `src/lib/aiur/run_telemetry/writer.ex` (`@external_event_patterns`, `@carried_point_events`), `src/test/aiur/run_telemetry/lifecycle_test.exs`, `src/test/aiur/run_telemetry/writer_test.exs`.
**Test scenarios:**
- A `ticket.42.ci.failed` exchange event with `head_sha` and `pr_number` gives a `ci_result` point with `outcome: "failed"`, and no failure excerpt is recorded.
- `ticket.42.pr.ready_for_review` gives a `pr_ready` point at the event timestamp.
- An unknown topic is still skipped.

### U2. Observed state transitions

**Goal:** `state_change` points on every observed transition.
**Files:** `src/lib/aiur/orchestrator/issue_sync.ex` (`emit_task_state_transition_alert/3`, or a sibling called beside it at about line 855), `src/test/aiur/orchestrator/issue_sync_telemetry_test.exs` (new; uses the `:run_telemetry_lifecycle_recorder` override from `lifecycle.ex:84`).
**Approach:** Record only when `previous_state != current_state` and both are non-nil. The attempt id comes from `state.running[issue.id].telemetry_attempt_id` when the ticket is running, and is nil otherwise.
**Test scenarios:**
- Transitions `in-progress → ci-wait → human-review → rework → ci-wait` give four `state_change` points, in order, with the correct from and to states.
- An unchanged state gives no record.
- A first observation (previous nil) gives no record.

### U3. Dependency cleared

**Goal:** A point on the dependent when a blocker is removed or becomes terminal.
**Files:** `src/lib/aiur/orchestrator/issue_sync.ex` (`emit_dependency_transition_events/3`, the removed branch and `maybe_enqueue_blocker_terminality_event`), the same new test file.
**Test scenarios:**
- A blocker that disappears from `blocked_by` gives `dependency_cleared{blocker, cause: "removed"}`.
- A blocker whose state turns terminal gives `cause: "terminal"`.
- A blocker that is newly added gives no record.

### U4. Ticket usage at terminal

**Goal:** Durable per-ticket token and spend totals.
**Files:** `src/lib/aiur/run_telemetry/usage_capture.ex` (new), `src/lib/aiur/run_telemetry/writer.ex` (trigger on a `pr_merged` append), `src/lib/aiur/run_telemetry/supervisor.ex` (Task.Supervisor child), `src/test/aiur/run_telemetry/usage_capture_test.exs`.
**Approach:** Dedupe per ticket per boot: emit at most once unless the totals change. Coverage takes the UsageAggregate coverage class.
**Test scenarios:**
- An aggregate with a ticket total of 120k in and 30k out tokens gives one `ticket_usage` point with those numbers.
- An aggregate that is unavailable gives a point with `coverage: "unavailable"` and no numbers, and the Writer is unaffected.
- A second merge event for the same ticket with equal totals gives no duplicate.

### U5. Binding kind sampling

**Goal:** Sample the binding gate.
**Files:** `src/lib/aiur/run_telemetry/sampler.ex` (`fleet_observation/1`), `analytics/lib/analytics/reduce.py` (`RESOURCE_EVIDENCE`), `src/test/aiur/run_telemetry/sampler_test.exs`, `analytics/tests/test_reduce.py`.
**Test scenarios:**
- A capacity map whose cap is full and has no hold gives `fleet_binding_kind: "config_cap"`.
- A capacity map with a `capacity_hold` gives `"admission"`.
- An unpublished snapshot gives nil, listed under `partial_fields`.

### U6. Reducers carry the new events

**Goal:** Both reducers keep the new events and fields.
**Files:** `analytics/lib/analytics/reduce.py` (`_lifecycle_event`), `src/lib/aiur/run_telemetry/dataset.ex`, `src/lib/aiur/run_telemetry/dashboard.ex` (phase colors for the new events), and tests.
**Test scenarios:** A fixture with every new event round-trips through both reducers with the same fields.

## Interfaces offered to other areas

- X2 metric pack definitions: CI wait means `ci-wait` dwell. A review round means each `state_change` into `rework` after the first `pr_opened`. Rework time runs from `rework` to the next `ci-wait` or `human-review`. Blocker clearance runs from `dependency_cleared` or the blocker's merge to the dependent's next `dispatch`.

## Risks

- **IssueSync is hot.** Mitigation: `Lifecycle.record` is already a fail-open cast, and the call adds no extra tracker reads.
- **Mid-run upgrades.** Tickets in flight when this ships have partial `state_change` history. The ledger marks such tickets with `capture_partial`.

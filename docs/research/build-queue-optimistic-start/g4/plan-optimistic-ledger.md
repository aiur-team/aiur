---
title: BQ-G4-1 Record optimistic starts durably - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g4/brainstorm.md
execution: code
epic: aiur-team/aiur#3755
code_baseline: origin/main 0e5b8d0de
---

# BQ-G4-1 Record optimistic starts durably - Plan

## Goal Capsule

- **Objective:** Every dispatch that starts a dependent before all its blockers
  are closed `completed` leaves one durable record, and one run-telemetry
  lifecycle event, that later code (failure policy BQ-G4-2, waste report
  BQ-G4-3) reads. No behavior change for non-optimistic dispatch.
- **Product authority:** brainstorm R1, R12, D5.
- **Product Contract preservation:** Product Contract unchanged.

## Problem Frame

Nothing in Aiur records that a dispatch was optimistic. The dispatcher records a
`dispatch` lifecycle point (`src/lib/aiur/orchestrator/dispatcher.ex`,
`spawn_issue_on_worker_host/6`) with complexity and worker host only. After a
restart, the orchestrator cannot tell an optimistic dependent from a normal
one, so it can neither react to its blocker failing nor count waste.

## Requirements

- R1 (origin). Durable record per optimistic start: dependent, each optimistic
  blocker (id, PR number, PR head SHA, PR state), trigger, start time.
- R12 (origin). Matching lifecycle telemetry event.
- L1. Record updates in place as the blocker evolves (new PR, new head SHA,
  merged, failed) and as the dependent integrates or is parked; counters live
  on the record (fields defined here, written by BQ-G4-2/3).
- L2. Records close when the dependent closes (any reason) and are pruned
  after 14 days closed.
- L3. Store failure never blocks dispatch: on write failure, dispatch proceeds,
  a warning is logged, and a `system.optimistic.ledger_unavailable` alert fires
  once per boot.

## Key Technical Decisions

- **KTD1. Standalone JSON store, not the build-queue store.** The queue store
  only matters when queues exist, and the live run has none. Use
  `Aiur.JsonStore` (atomic rename) at the per-repo state node, beside the
  queue store (`Aiur.Config.Paths`, same resolution as
  `src/lib/aiur/build_queue/store.ex`). File: `optimistic-starts.json`.
- **KTD2. Owned by a small GenServer `Aiur.Orchestrator.OptimisticLedger`.**
  Serialized writes, ETS reads for the dashboard and planner. Started under the
  orchestrator supervisor before the orchestrator.
- **KTD3. The dispatcher writes the record; G1 supplies the blocker list.**
  Assumed G1 interface: the dispatch decision carries
  `optimistic_blockers` (ids of `blocked_by` blockers that were open but
  satisfied by the trigger) and `start_trigger`. Until G1 lands, the
  dispatcher computes the list itself from `issue.blocked_by` entries whose
  state is non-terminal; that list is empty today because the gate refuses such
  dispatches, so the change is inert until G1 ships.
- **KTD4. New lifecycle event `optimistic_start` (point).** Add to `@events`
  in `src/lib/aiur/run_telemetry/lifecycle.ex`, plus metadata fields
  `start_trigger`, `blockers` (list of ids), `blocker_prs`. Reuses the existing
  attempt id so the reducer can join it to the dispatch.
- **KTD5. Record schema versioned (`"v": 1`).** Unknown versions load as
  read-only and are not pruned.

## High-Level Technical Design

Record shape (directional):

```
ticket, attempt_id, start_trigger, started_at_ms, status (running|parked|closed)
blockers: [{id, pr_number, pr_head_sha_at_start, pr_state, last_head_sha,
            failed_cause, failed_at_ms, merged_at_ms}]
counters: {pushes_absorbed, integrations_clean, integrations_conflict,
           non_ff_pushes, parks, resumes_after_park}
outcome: nil | merged | merged_after_redo | discarded
closed_at_ms
```

## Implementation Units

### U1. Ledger store and process

**Goal:** Durable, versioned store with read/write API.
**Requirements:** R1, L1, L2, L3.
**Dependencies:** none.
**Files:** `src/lib/aiur/orchestrator/optimistic_ledger.ex` (new),
`src/lib/aiur/orchestrator/supervisor.ex` or the application child list that
starts the orchestrator (add child), `src/test/aiur/orchestrator/optimistic_ledger_test.exs` (new).
**Approach:** API: `record_start/2`, `update_blocker/3`, `bump/3`,
`set_status/3`, `close/3`, `get/1`, `open_records/0`, `by_blocker/1`.
Persist on every write. Prune closed records older than 14 days on boot.
**Patterns to follow:** `Aiur.ExecutorWakeInbox` (GenServer + JsonStore),
`Aiur.BuildOrder.History` (ETS reads).
**Test scenarios:**
- record_start then get returns the record with counters at zero.
- Restart (stop and start the process with the same path) keeps open records.
- `by_blocker("12")` returns every open dependent of #12, not closed ones.
- Corrupt file: process starts, reads empty, emits the ledger-unavailable
  alert once, refuses writes with `{:error, :ledger_unavailable}`.
- Closed record 15 days old is pruned at boot; 13 days old is kept.
- Version 2 record on disk is kept and never mutated.
**Verification:** tests pass; file is valid JSON after each write.

### U2. Dispatcher writes the record and the lifecycle event

**Goal:** One record and one `optimistic_start` event per optimistic dispatch.
**Requirements:** R1, R12, KTD3, KTD4.
**Dependencies:** U1; G1 dispatch decision for real data (inert before).
**Files:** `src/lib/aiur/orchestrator/dispatcher.ex`
(`spawn_issue_on_worker_host/6`), `src/lib/aiur/run_telemetry/lifecycle.ex`
(`@events`, `@metadata_fields`), `src/test/aiur/orchestrator/dispatcher_test.exs`,
`src/test/aiur/run_telemetry/lifecycle_test.exs`.
**Approach:** After the `dispatch` point, if `optimistic_blockers` is
non-empty, call `OptimisticLedger.record_start/2` with the blocker PR facts the
tracker already returned for the gate (no extra GitHub call at dispatch; if a
PR fact is missing, store `nil` and let BQ-G4-2's reconcile fill it). Then
record the `optimistic_start` lifecycle point. A ledger error logs and
continues (L3).
**Test scenarios:**
- Dispatch with two open blockers writes one record with two blockers and
  emits one `optimistic_start` event with the same attempt id as `dispatch`.
- Dispatch with no open blockers writes nothing and emits no event.
- Ledger returns an error: dispatch still starts the runner; a warning is logged.
- Lifecycle accepts `optimistic_start` and drops unknown metadata keys.
**Verification:** dispatcher test asserts runner start plus ledger contents.

### U3. Close records on dependent terminal states

**Goal:** Records close when the dependent's issue closes or PR merges.
**Requirements:** L1, L2.
**Dependencies:** U1.
**Files:** `src/lib/aiur/orchestrator/optimistic_ledger.ex`,
`src/lib/aiur/orchestrator/event_topics.ex` (route `ticket.*.pr.merged` for
dependents to the ledger), `src/test/aiur/orchestrator/optimistic_ledger_test.exs`.
**Approach:** On dependent `pr.merged`, set outcome `merged` (or
`merged_after_redo` when `parks > 0`); on issue closed `not_planned` or PR
closed unmerged with the issue closed, outcome `discarded`. BQ-G4-3 emits the
outcome telemetry; this unit only stores it.
**Test scenarios:**
- Dependent PR merges with `parks == 0` -> outcome `merged`, status closed.
- Dependent PR merges with `parks == 1` -> `merged_after_redo`.
- Dependent issue closed not_planned -> `discarded`.
- Event for a ticket with no record is ignored.
**Verification:** tests pass.

## Scope Boundaries

- Out: acting on blocker failure (BQ-G4-2), reports and page (BQ-G4-3),
  deciding which dispatch is optimistic (G1).

## Risks & Dependencies

- G1 interface may differ in naming; the dispatcher seam is one call site, so
  adapting is cheap.
- Telemetry field `blockers` is a list; the reducer must tolerate lists
  (check `_lifecycle_event` in `analytics/lib/analytics/reduce.py`, which
  copies named fields only; BQ-G4-3 adds it).

## Documentation Plan

- `website/docs-app/concepts/build-orders.md`: one paragraph under the G1
  start-trigger section naming the optimistic-start record and its file.

## Definition of Done

- U1-U3 tests pass; `mix test` for touched files green; CI green on the head SHA.
- With G1 absent, no record is ever written (inert).

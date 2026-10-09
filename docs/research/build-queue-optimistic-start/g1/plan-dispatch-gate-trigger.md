---
title: BQ-G1-3 Dispatch blocked_by gate follows the start trigger - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g1/brainstorm.md
epic: aiur-team/aiur#3755
---

# BQ-G1-3 Dispatch blocked_by gate follows the start trigger - Plan

## Summary

Replace `DispatchPolicy.todo_issue_blocked_by_non_terminal?/2` with `todo_issue_held_by_dependency?/2`, which evaluates each `blocked_by` entry through `Aiur.StartTrigger.edge_verdict/3` using the ticket's effective trigger. Move every caller in the same PR. Record which blockers a start was optimistic about, for G2-G5.

Product Contract unchanged (see origin).

---

## Problem Frame

Dispatch holds a `todo` ticket while any blocker's state is not in `tracker.terminal_states` (`src/lib/aiur/orchestrator/dispatch_policy.ex:857`, :987). The queue can promote a dependent under `pr_opened`, and dispatch then declines it as `:dependency`. Promotion and dispatch must agree (R4).

## Requirements

R2, R4, R8, R9 from the origin.

---

## Key Technical Decisions

- **KTD1. Effective trigger.** `Aiur.StartTrigger.trigger_for(issue_id)` reads the queue hints row (`:aiur_build_queue_hints`, extended in this PR to `{issue_id, sort_key, held?, trigger}`; `Hints.lookup/1` accepts the old 3-tuple) and falls back to `Settings.start_trigger/1`. Queue reconcile writes the queue's effective trigger in the row.
- **KTD2. Evidence from the hydrated blocker.** A `blocked_by` entry carries `%{id, identifier, state, url}`. The builder maps `state` (`"Closed"` -> `issue_open?: false`; other states -> `state_label`), adds the `ProgressStore` row (BQ-G1-2) and the blocker's `RecentMergeStore` merge, and stamps `observed_at_ms` from the hydration time. An entry with `state: nil` stays fail-closed: verdict `{:unknown, :blocker_state_unreadable}` holds.
- **KTD3. Dispatch failure semantics are preserved (R8).** Dispatch calls the policy with `not_planned: :satisfy`, and maps terminal states other than `Closed` (`Cancelled`, `Duplicate`, `Done` per `tracker.terminal_states`) exactly as today: `Done` is a `pr_merged` final stage; `Cancelled`/`Duplicate` no longer hold. `{:failed, :pr_closed_unmerged}` and `{:failed, :agent_error}` hold the dependent (no start on a dead blocker; G4 decides about running ones).
- **KTD4. The gate stays pure.** It reads only ETS (hints, progress) and in-memory stores. It registers `pr_approved` watches through `ProgressStore.watch/2` (cast) and never calls GitHub.
- **KTD5. Optimistic record.** `DispatchPolicy.optimistic_blockers(issue)` returns blocker ids whose verdict was `{:satisfied, :optimistic}`. The dispatcher stores it on the running entry (`optimistic_blockers`) and includes it in the dispatch event payload. This is the interface G2 (subscribe), G3, G4 and G5 consume.
- **KTD6. One rename, all callers.** Callers: `dispatch_policy.ex` (:857, :956), `dispatch_candidates.ex` (:23, :27), `status_report.ex` (:1273), `issue_sync.ex` (:242, :2321, :2356), `pause_resume.ex` (:2414), `dispatcher.ex` (:1251, :1298, :1405), `waiting_reason.ex` doc reference. `non_terminal_blockers/2` becomes `holding_blockers/2` with the same "only what holds" contract used by `describe_dependency_hold/2`. No compatibility alias: a leftover old-name caller fails to compile.

---

## Implementation Units

### U1. Trigger in the hints table

**Goal:** dispatch can know a ticket's trigger.
**Dependencies:** BQ-G1-1.
**Files:** `src/lib/aiur/build_queue/hints.ex`, `src/lib/aiur/build_queue/reconcile.ex`, `src/lib/aiur/start_trigger.ex` (`trigger_for/1`); tests `src/test/aiur/build_queue/hints_test.exs`, `src/test/aiur/start_trigger_test.exs`.
**Test scenarios:**
- Row with trigger `:pr_opened` -> `trigger_for/1` returns it; no row -> config default; table absent -> config default.
- Old 3-tuple row (written by a running older server during a hot upgrade) -> config default, no crash.

### U2. Gate on the shared policy

**Goal:** dispatch holds and releases by trigger.
**Dependencies:** U1, BQ-G1-1 U1. Uses BQ-G1-2 rows when present; works without them.
**Files:** `src/lib/aiur/orchestrator/dispatch_policy.ex`, `src/lib/aiur/start_trigger/evidence.ex` (blocker builder); tests `src/test/aiur/orchestrator/dispatch_policy_test.exs`.
**Approach:** KTD2-KTD4. Hold when any blocker verdict is `:pending`, `{:unknown, _}` or `{:failed, _}` (after KTD3 mapping).
**Test scenarios:**
- Default config, blocker `in-progress`: held (unchanged).
- Default config, blocker `Done`: dispatch (unchanged). Blocker `Cancelled`: dispatch (unchanged, R8).
- Default config, blocker `human-review` with a `RecentMergeStore` merge: dispatch (AE2).
- Trigger `pr_opened` from hints, blocker `ci-wait`: dispatch; `in-progress` with no row: held.
- Trigger `pr_opened`, blocker `ci-wait`, progress row `closed_unmerged?`: held (AE5).
- Blocker `state: nil`: held under every trigger.
- Two blockers, one satisfied optimistic and one pending: held.

### U3. Move every caller

**Goal:** the status board, auto-resume, candidate filter and dispatcher all agree.
**Dependencies:** U2.
**Files:** `src/lib/aiur/orchestrator/dispatch_candidates.ex`, `status_report.ex`, `issue_sync.ex`, `pause_resume.ex`, `dispatcher.ex`, `waiting_reason.ex`; tests `src/test/aiur/orchestrator/dispatch_candidates_test.exs`, `status_report_test.exs`, `issue_sync_test.exs`, `pause_resume_test.exs`, `dispatcher_test.exs`, `dispatcher_stale_blocked_by_test.exs`.
**Test scenarios:**
- Integration: ticket under `pr_opened` with blocker in `ci-wait` is not counted as `waiting_for_dependency` by the status report, is not declined `:dependency` by `dispatcher.ex` pre-refresh and post-refresh paths, and is resumable by `pause_resume.ex`.
- A dependency-paused agent (`pause_resume.ex:2414`) is released when its blocker reaches the ticket's trigger stage.

### U4. Record optimistic starts

**Goal:** G2-G5 can see an optimistic start.
**Dependencies:** U2.
**Files:** `src/lib/aiur/orchestrator/dispatch_policy.ex` (`optimistic_blockers/1`), `src/lib/aiur/orchestrator/dispatcher.ex`, `src/lib/aiur/orchestrator/state.ex` (running entry field); tests `src/test/aiur/orchestrator/dispatcher_test.exs`.
**Test scenarios:**
- Dispatch under `pr_opened` with blocker in `ci-wait`: running entry has `optimistic_blockers: ["12"]`; dispatch event payload carries it (AE1).
- Dispatch with all blockers final: `optimistic_blockers: []`.

---

## Risks

- **Many callers, one semantics change.** Mitigated by the rename (compile-time) and U3 integration tests.
- **Hot path cost.** Two ETS lookups per blocker per evaluation; no network. Same order as `Hints.held?/1` today.

## Documentation

Update the `DispatchPolicy` moduledoc and `website/docs-app/concepts/ticket-lifecycle.md` "Build queue" paragraph on dispatch holds (BQ-G1-4 owns the full concept text).

## Definition of Done

- U1-U4 tests pass; no reference to `todo_issue_blocked_by_non_terminal?` remains in `src/`.
- Live check: a queue under `pr_opened` gets its dependent promoted and dispatched within one reconcile plus one dispatch tick of the blocker entering `ci-wait`.

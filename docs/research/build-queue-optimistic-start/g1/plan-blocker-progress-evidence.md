---
title: BQ-G1-2 Blocker PR progress evidence store - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g1/brainstorm.md
epic: aiur-team/aiur#3755
---

# BQ-G1-2 Blocker PR progress evidence store - Plan

## Summary

Add `Aiur.StartTrigger.ProgressStore`: one row per blocker ticket recording the highest PR stage reached for its current PR number. Writers are facts the daemon already holds (CI lifecycle `passed_heads`, webhook `pull_request` deliveries, `RecentMergeStore`) plus one conditional review read for blockers under `pr_approved`. Readers are the queue (via `PRObserver`) and dispatch (BQ-G1-3), both through `StartTrigger.Evidence.stage_reached`.

Product Contract unchanged (see origin).

---

## Problem Frame

Labels alone (BQ-G1-1) regress: the daemon swaps `ci-wait` to `in-progress` when CI passes, and `rework` follows review. R6 needs a monotonic per-PR record, and `pr_approved` needs a review fact that no label carries until `merging`.

## Requirements

R5, R6, KD2, KD3 from the origin.

---

## Key Technical Decisions

- **KTD1. Row shape.** `{ticket_id, %{pr_number, stage, closed_unmerged?, observed_at_ms, source}}`; `stage` is a ladder atom from `Aiur.StartTrigger`. Advancing is max-only for the same `pr_number`. A different `pr_number` replaces the row. A closed-unmerged delivery sets `closed_unmerged?: true` and clears `stage`.
- **KTD2. Owner and access.** A GenServer owns a `:protected`, `read_concurrency` ETS table `:aiur_start_trigger_progress`; writes go through `record/2` (cast); reads are direct ETS lookups so the dispatch gate stays cheap and pure-callable. Missing table reads as "no row" (dispatch keeps working when the store is down), mirroring `Aiur.BuildQueue.Hints`.
- **KTD3. No new CI classifier.** `pr_ci_green` comes only from `CiLifecycle.remember_ci_approved_head/3` when `decision == :passed` (`src/lib/aiur/orchestrator/ci_lifecycle.ex`, the `passed_heads` update). Boot seeds rows from `Aiur.CIApprovalStore.load/0` `passed_heads`, so a restart does not lose greens (R6). The PR number comes from the CI result's `pr_number`.
- **KTD4. Webhook deliveries are identity and terminal facts only.** In `Aiur.Events.GithubWebhook.Deposit`, where a `pull_request` body is deposited under `:branch_pull_request`, record: open and `draft == false` -> `:pr_opened`; `merged` -> `:pr_merged`; closed unmerged -> `closed_unmerged?`. Never CI or review state from a delivery (same rule as `Aiur.GitHub.DeliveredPullRequest`).
- **KTD5. Merges.** `RecentMergeStore.upsert/1` callers (`src/lib/aiur/events/github_firehose.ex`) also record `:pr_merged` for the merge's ticket.
- **KTD6. Approval read is demand-scoped.** The queue reconcile and the dispatch gate call `ProgressStore.watch(ticket_ids, :pr_approved)` for blockers whose dependent's trigger is `pr_approved`. The store refreshes watched tickets at most once per `observation_max_age_ms / 2`, using a newly public `Aiur.GitHub.HumanReviewGate.approved_pull_request?/2` (the existing `approved?/2` standing-verdict rule, conditional ETag read through `ResourceFetch`). Watches expire after two missed renewals. Read failure leaves the row unchanged and logs once.
- **KTD7. Staleness.** A positive stage is a fact about a PR and does not expire. The `Evidence` builder still requires fresh issue labels (queue `Observation` freshness, dispatch hydration) before any verdict, so a stale world reads `{:unknown, :stale}` (R5). A row older than 24h with no positive stage is ignored.

---

## Implementation Units

### U1. Store process and table

**Goal:** the store exists, is supervised and readable.
**Dependencies:** BQ-G1-1 U1 (ladder atoms, `Evidence`).
**Files:** create `src/lib/aiur/start_trigger/progress_store.ex`; modify `src/lib/aiur.ex` (child list, next to `Aiur.RecentMergeStore`); test `src/test/aiur/start_trigger/progress_store_test.exs`.
**Approach:** KTD1, KTD2, KTD7. `lookup/1` returns the row or `nil`; `record/2` applies max-only merge in the server.
**Test scenarios:**
- Record `:pr_opened` then `:pr_ci_green` for PR 99: stage is `:pr_ci_green`; recording `:pr_opened` again does not lower it.
- Record `:pr_ci_green` for PR 99 then `:pr_opened` for PR 120: row resets to PR 120 at `:pr_opened`.
- Closed-unmerged for PR 99 clears the stage and sets the flag.
- `lookup/1` with the table absent returns `nil` without raising.

### U2. Writers: CI lifecycle, deliveries, merges, boot seed

**Goal:** rows fill from existing facts.
**Dependencies:** U1.
**Files:** `src/lib/aiur/orchestrator/ci_lifecycle.ex`, `src/lib/aiur/events/github_webhook/deposit.ex`, `src/lib/aiur/events/github_firehose.ex`, `src/lib/aiur/start_trigger/progress_store.ex` (boot seed); tests `src/test/aiur/orchestrator_ci_lifecycle_test.exs`, the deposit tests under `src/test/aiur/events/`, `src/test/aiur/start_trigger/progress_store_test.exs`.
**Approach:** KTD3-KTD5. Each writer is one `record/2` call after the fact it already persists; a write failure never fails the writer.
**Test scenarios:**
- A CI poll result `decision: :passed, pr_number: 99` for ticket 12 records `:pr_ci_green`; `:pending` and `:failed` record nothing.
- A delivered `pull_request` with `draft: true` records nothing; `ready_for_review` (draft false) records `:pr_opened`; `closed` with `merged: true` records `:pr_merged`; `closed` with `merged: false` sets `closed_unmerged?`.
- Boot with a `ci-approvals.json` holding `passed_heads["12"]` seeds ticket 12 at `:pr_ci_green`.
- Integration: deposit a merged delivery for 12, then `Aiur.StartTrigger.edge_verdict(:pr_merged, evidence_for_open_issue_12, opts)` is `{:satisfied, :final}`.

### U3. Approval watch

**Goal:** `pr_approved` has evidence.
**Dependencies:** U1.
**Files:** `src/lib/aiur/github/human_review_gate.ex` (public `approved_pull_request?/2`), `src/lib/aiur/start_trigger/progress_store.ex`; tests `src/test/aiur/github/human_review_gate_test.exs`, `src/test/aiur/start_trigger/progress_store_test.exs`.
**Approach:** KTD6. Use the store's injected reader in tests (no network).
**Test scenarios:**
- Watched ticket with standing APPROVED records `:pr_approved`; APPROVED plus a later CHANGES_REQUESTED from another reviewer does not.
- Approval recorded, then a dismissal: stage stays `:pr_approved` (R6).
- Unwatched ticket is never read; watch not renewed for two periods is dropped.
- Reader error leaves the row as it was.

### U4. Queue reads the store

**Goal:** queue evidence includes `stage_reached`.
**Dependencies:** U1, BQ-G1-1 U3.
**Files:** `src/lib/aiur/build_queue/pr_observer.ex`, `src/lib/aiur/build_queue/reconcile.ex`, `src/lib/aiur/build_queue/model.ex` (`Observation.stage_reached`, transient, never persisted); tests `src/test/aiur/build_queue/pr_observer_test.exs`, `readiness_test.exs`.
**Approach:** `PRObserver.observe/2` copies the row's stage and `closed_unmerged?` into the transient observation (row `closed_unmerged?` maps to `pr: :closed_unmerged`). Reconcile registers `pr_approved` watches for prerequisites of dependents under that trigger.
**Test scenarios:**
- Prerequisite labelled `in-progress` with row `:pr_ci_green`, queue trigger `pr_ci_green`: dependent `:ready` (AE3).
- Row `closed_unmerged?` with label `human-review`: `{:failed, :pr_closed_unmerged}` (AE5).
- No row, label `ci-wait`, trigger `pr_ci_green`: `:waiting`.

---

## Risks

- **GitHub cost.** Only the approval read is new, conditional and demand-scoped; at 50 watched blockers and a 60s observation age that is at most 100 conditional reads per minute, mostly 304. Verify with `github-budget` after rollout.
- **Writer coupling.** CI lifecycle and deposit gain one call each; failures are swallowed and logged, so the store cannot break CI handling.

## Documentation

Configuration reference note that `pr_approved` adds a review read per watched blocker.

## Definition of Done

- U1-U4 tests pass.
- On a live daemon, a blocker that passed CI then returned to `in-progress` still satisfies `pr_ci_green` after a daemon restart.

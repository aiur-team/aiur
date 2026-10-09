---
title: EXP-X1-1 PR-open fidelity - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x1/brainstorm.md
ticket: EXP-X1-1
complexity: 1
---

# EXP-X1-1 PR-open fidelity - Plan

## Summary

Make start→PR-open correct and visible. Three changes: (1) the Python reducer must stamp a GitHub `pr.opened` record with the PR's `created_at`, (2) the live analytics presenter must read `pr_opened`, and (3) the Elixir and Python reducers must agree on one shared fixture.

## Problem Frame

- `analytics/lib/analytics/reduce.py:366-368` sets the timestamp of both `pr.opened` and `pr.merged` from `merged_at or closed_at or created_at`. For an enriched merged PR, `pr_opened` therefore lands at merge time, and start→PR-open equals start→merge.
- The Elixir path is already correct: `src/lib/aiur/run_telemetry/lifecycle.ex:533-540` picks `created_at` for `pr.opened` and `merged_at` for `pr.merged`. The two reducers disagree, and the Python one writes the durable run summaries (`src/lib/aiur/run_telemetry/summaries.ex:160-170`).
- `src/lib/aiur_web/operator_control_center/analytics/presenter.ex` `ticket_row/3` (about lines 741-764) reads `implement`, `agent_spinup`, `build_test` and `pr_merged`, but never `pr_opened`. The ticket timeline cannot show a PR-open marker, and the status is never "in review".

Requirements: R1, R2 (brainstorm).

## Key Technical Decisions

- **KTD1.** Per-kind timestamp choice in Python mirrors `Lifecycle.external_timestamp_candidates/2`: `pr.opened` uses `created_at`, then the event timestamp; `pr.merged` uses `merged_at`, then `closed_at`, then the event timestamp. Reason: one rule in both languages.
- **KTD2.** The presenter adds `pr_opened_at` to each ticket row, plus a `:in_review` status (PR open, not merged, no rework). It takes the earliest `pr_opened` point. Reason: a ticket can reopen a PR, and the first open is the "time to PR" milestone.
- **KTD3.** Parity is enforced by a shared fixture under `analytics/tests/fixtures/` that an Elixir test also reads. Reason: the reducers already share fixtures (`analytics/tests/fixtures/session-a`). This adds an assertion that the derived PR-open and merge times agree.

## Implementation Units

### U1. Fix the Python GitHub record timestamp

**Goal:** `pr.opened` records carry `created_at`.
**Files:** `analytics/lib/analytics/reduce.py` (`_github_record`), `analytics/tests/test_reduce.py`.
**Approach:** Branch on `kind`, as in KTD1. Leave comment handling unchanged.
**Test scenarios:**
- A PR with `created_at=T1` and `merged_at=T2` gives a `pr_opened` record at T1 and a `pr_merged` record at T2. This fails on main today: both land at T2.
- A PR with no `created_at` falls back to the event `timestamp`.
- An open, unmerged PR gives only `pr_opened`, at `created_at`.
**Verification:** The new tests pass, and existing `test_reduce.py` tests still pass.

### U2. Read pr_opened in the presenter

**Goal:** Ticket rows expose `pr_opened_at`, and their status reflects review.
**Files:** `src/lib/aiur_web/operator_control_center/analytics/presenter.ex` (`ticket_row/3`, `ticket_status/2`), `src/lib/aiur_web/operator_control_center/analytics/charts.ex` (draw a PR-open tick on the ticket lane, if the lane chart has markers), `src/test/aiur_web/operator_control_center/analytics/latest_run_test.exs` or a new `presenter_ticket_row_test.exs`.
**Approach:** Use `phase_start(intervals, ["pr_opened"])`, project it through `Timeline.project`, and add the row field. The status order is merged, then rework, then paused, then in_review, then active.
**Test scenarios:**
- A dataset with dispatch, pr_opened and no merge gives a row with `pr_opened_at` set and status `:in_review`.
- A dataset with pr_opened twice (reopen) uses the earliest one.
- A dataset without pr_opened gives `pr_opened_at: nil` and no crash.
**Verification:** `/analytics` shows the PR-open marker for an open PR. Check this with the fixture parity run (memory: OCC dashboard local parity run).

### U3. Cross-reducer parity fixture

**Goal:** The Elixir `Dataset` and the Python reducer agree on PR-open and merge milestones.
**Files:** `analytics/tests/fixtures/pr-timing/telemetry.ndjson` and `github-events.json` (new), `analytics/tests/test_reduce.py`, `src/test/aiur/run_telemetry/dataset_test.exs`.
**Approach:** One fixture with a live `pr_opened`, an enriched `pr.opened`/`pr.merged` pair, and a reconciliation record. Both tests assert the same per-ticket first-`pr_opened` and `pr_merged` timestamps, hard-coded in both tests.
**Test scenarios:** Both reducers give the same timestamps. A deliberate swap of the `created_at` and `merged_at` values fails both tests.

## Scope Boundaries

- Cross-launch stitching is out of scope here. A ticket whose PR opened in an earlier launch still lacks `pr_opened` in later run summaries; EXP-X1-5 (ledger) fixes that.

## Risks

- Existing materialized run summaries keep the wrong timestamp until they are regenerated. Mitigation: the analytics README notes that `analytics/reduce --all` rewrites them. EXP-X1-5 backfill regenerates anyway.

## Documentation

- `analytics/README.md`: one line on the PR-open timestamp rule.

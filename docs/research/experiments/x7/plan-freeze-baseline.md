---
title: EXP-X7-0 Freeze the optimistic-start baseline - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
origin: docs/research/experiments/x7/brainstorm.md
execution: data
epic: aiur-team/aiur#3774
status: done 2026-10-09 (Executor)
---

# EXP-X7-0 Freeze the optimistic-start baseline - Plan

## Summary

- **What.** Capture, before #3763 merges, the per-dependent flow times that optimistic start is meant to change, and store them read-only.
- **Status.** Executed by the Executor on 2026-10-09. The data cut is 2026-10-09T17:55:20Z, and #3763 was still open then.
- **Where it lives.**
  - `docs/research/experiments/x7/baseline-2026-10-09/`
  - `~/.aiur/repo/aiur-team/aiur/executor/experiments/optimistic-start-baseline/`

## Requirements

R1 and R2 of the origin brainstorm (frozen baseline; primary metrics stratified by complexity), plus the R4 decision metric and the R6 guardrail baselines.

## Key Technical Decisions

- **KTD1. GitHub is the primary source; telemetry is a cross-check.** Telemetry on disk starts 2026-10-08T02:00Z, which is retention loss. The GitHub label and PR timelines are complete.
- **KTD2. Use read-only scripts, not the reducer.** `analytics/lib/analytics/reduce.py` reads `pr.opened` time from `merged_at` first. It also does not read native `blocked_by`. Using it would bias the PR-open timing.
- **KTD3. Parse untrusted files with `python3 -I`.** Telemetry and run summaries are parsed as JSON and never executed.
- **KTD4. Read GitHub as its-everdred.** `gh` runs with `GITHUB_TOKEN`/`GH_TOKEN` unset. Search is split by day to stay under the 1000-result cap, and every referenced blocker is fetched as well.

## Implementation Units (executed)

### U1. Extract lifecycle events

- **Script:** `method/extract_events.py`.
- **Input:** every `~/.aiur/logs/*/log/telemetry.ndjson` and every `analytics/runs/*/run-summary.json`.
- **Output:** the point events `dispatch`, `pr_opened` and `pr_merged`, plus the starts of `agent_spinup` and `implement`.
- **Dedup key:** (ticket, event, attempt, timestamp, PR). Carried events repeat across boots, so the key removes the copies.
- **Verification:** 8,310 unique events. 0 lines failed to parse.

### U2. Fetch GitHub issue graph and timelines

- **Scripts:** `method/fetch_gh.py` and `method/fetch_links.py`.
- **Per issue:** `blockedBy`, `blocking`, labels, label and close timeline, closing PRs (created, ready, merged), and `BlockedByAddedEvent`.
- **Verification:** 609 issues fetched. 366 of them have `blocked_by` links.

### U3. Compute flow metrics and strata

- **Script:** `method/compute.py`.
- **Writes:** `dependents.csv`, `edges.csv`, `program-tickets-flow.csv` and `baseline.json`.
- **Statistics:** medians, IQR and n, by complexity and by hub/chain.
- **Rules:**
  - Late-linked dependents are excluded.
  - A dependent that started before its blocker merged appears only when its link was late.
- **Verification:** the result was checked by hand on #3329. Its blocker #3257 merged, then #3330 started.
  - Telemetry dispatch vs label differ by a median of 1.3 min, with n = 34.

### U4. Guardrail baselines and power

- **Script:** `method/guardrails.py` writes rework, discard and error rates, and the main `ci` push failure rate (from the Actions runs API).
- **Script:** `method/power.py` simulates Mann-Whitney power by resampling the baseline.

### U5. Freeze and publish

- **Freeze.** Copy the files to both locations. Write `README.md` (method, definitions, counts, caveats).
- **Ticket comments.**
  - Comment on #3763 with the location.
  - Close EXP-X7-0 with links.
- **No `blocked_by` link from #3763.** The baseline is frozen, so #3763 is not held.

## Test expectation

None: this is a data capture, not product code. The checks are the counts and cross-checks in U1-U3. Any new data goes into a new dated snapshot directory. Nothing here is overwritten.

## Risks

- **Small, clustered sample (n = 27; 19 from one hub).**
  - The spec reports the chain-gated stratum on its own.
  - It requires a cluster bootstrap.
- **Labels are agent-written.** A human re-adding `agent:in-progress` would not move the start, because the first label event is used.

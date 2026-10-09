---
title: EXP-X4-3 Right-censored durations (open tickets) - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x4/brainstorm.md
ticket: EXP-X4-3
complexity: 2
---

# EXP-X4-3 Right-censored durations (open tickets) - Plan

## Summary

Treat tickets that are still open at snapshot time as right-censored observations:
Kaplan-Meier medians with intervals, log-rank test, equal follow-up truncation, and the
completed-only rank test kept as a sensitivity analysis.

## Problem Frame

An "after" window is younger than its "before" window. If open tickets are dropped, the
after group keeps only the tickets that finished fast, and the feature looks better than
it is. This bias is largest exactly when Kevin first looks at a new feature.

## Requirements

Brainstorm R6, KD4. Removes the temporary `censoring_ignored` flag of EXP-X4-2 KTD1.

## Assumed interfaces

- X1/X2: each duration row has `censored: true` and `value` = elapsed seconds from the
  start event to `snapshot.taken_at` when the end event has not happened. Units that never
  started are absent, not censored.

## Key Technical Decisions

- **KTD1. Primary method switch.** If any row in either group is censored, the primary
  test is the log-rank test and the primary location estimate is the KM median; MWU on
  completed rows moves to `sensitivity`. With no censored rows, EXP-X4-2's path is
  unchanged (results byte-identical).
- **KTD2. Equal follow-up.** Let tau = min over groups of the maximum follow-up
  observed. Every row with value > tau is censored at tau before analysis. Recorded as
  `follow_up_horizon_s` and flag `follow_up_truncated` when it changed any row.
- **KTD3. Intervals.** KM median interval by Brookmeyer-Crowley with the log-log
  transformed Greenwood variance (lifelines default). Median difference interval by
  bootstrap of KM medians (EXP-X4-1 bootstrap with a KM statistic); resamples where a
  median is not reached are counted and reported; when more than 10% of resamples do not
  reach a median the interval is withheld and the flag `median_not_reached` set.
- **KTD4. Flags.** `censoring_heavy` when either group has more than 20% censored rows
  after truncation; `median_not_reached` when the KM curve does not cross 0.5. Status is
  then `inconclusive` at best for that metric (the summary says "median not yet reached").
- **KTD5. Stratified log-rank** is exposed as a function taking a strata map; EXP-X4-4
  calls it.

## Implementation Units

### U1. Kaplan-Meier and log-rank

**Files:** `analytics/lib/analytics/stats/survival.py`, `analytics/tests/test_stats_survival.py`,
`analytics/tests/fixtures/stats/goldens.json` (survival section), generator update in
`analytics/tests/fixtures/stats/generate_goldens.py` (lifelines 0.29).
**Test scenarios:**
- KM survival curve, median and Brookmeyer-Crowley interval match lifelines on 4
  fixtures (no censoring, light, heavy, tied event times).
- Log-rank chi-square and p match `lifelines.statistics.logrank_test`; stratified version
  matches the sum-over-strata statistic on a 3-stratum fixture.
- All rows censored: median not reached, no exception.
- No censoring: KM median equals the type-7 sample median only where the definitions
  agree; the test documents the expected difference on even n (KM uses the first time
  S(t) ≤ 0.5).

### U2. Driver integration and truncation

**Files:** `analytics/lib/analytics/stats/analyze.py`, `analytics/lib/analytics/stats/summary_text.py`,
`analytics/schema/experiment-result.v1.json` (add `survival{}`, `sensitivity{}`,
`follow_up_horizon_s`, new flags), `analytics/tests/test_stats_analyze.py`.
**Test scenarios:**
- Bias fixture: before window 40 tickets all closed; after window 40 tickets where the
  10 slowest are still open. Completed-only MWU says `significant improved`; the primary
  (log-rank) result says `inconclusive` with `censoring_heavy`. This is the regression the
  ticket exists for.
- Follow-up truncation changes rows → `follow_up_truncated` set, horizon recorded.
- Fixture without censoring → result body byte-identical to EXP-X4-2 output.
- Summary sentence for `median_not_reached` names the fraction still open.

### U3. Methods page section

**Files:** `website/docs-app/reference/experiment-statistics.md`.
**Test expectation:** none -- docs.

## Verification Contract

Analytics CI green; lifelines goldens within 1e-6; the bias fixture assertion passes.

## Risks

- **Start-time fidelity.** Censoring is only as good as the start event (X1). If X1 cannot
  supply open-ticket start times, the engine raises `censoring_unknown` and falls back to
  completed-only with that flag, never silently.

## Definition of Done

Duration metrics with open tickets report KM medians and log-rank p as primary, and the
bias fixture proves the fix.

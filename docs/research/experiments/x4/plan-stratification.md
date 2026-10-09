---
title: EXP-X4-4 Stratification by complexity and other strata - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x4/brainstorm.md
ticket: EXP-X4-4
complexity: 2
---

# EXP-X4-4 Stratification by complexity and other strata - Plan

## Summary

Compare like with like: per-stratum results (default stratum: ticket complexity), a
pooled stratified test (van Elteren for uncensored, stratified log-rank for censored), a
composition-standardized median difference, and a `composition_shift` flag when the
stratum mix differs between groups.

## Problem Frame

Operator decision: "compare same-complexity tickets where possible". If the after window
happens to hold more complexity-1 tickets, a pooled median falls with no real change
(Simpson's paradox). Complexity is already recorded at dispatch
(`analytics/lib/analytics/reduce.py:582`, `:636-640`); it is a pre-treatment covariate.

## Requirements

Brainstorm R7.

## Key Technical Decisions

- **KTD1. Strata come from the spec** (`strata: ["complexity"]` default; any row
  attribute allowed, e.g. `backend`, `model`, consumer tags). Rows with a missing stratum
  value go to an explicit `unknown` stratum, never dropped silently. Crossing two strata
  only when the spec lists a tuple.
- **KTD2. Per-stratum results** reuse the EXP-X4-2 per-metric path with the same guard;
  they are always `exploratory` and BH-adjusted.
- **KTD3. Pooled test.** van Elteren (stratum weights 1/(n_s+1)) for uncensored
  continuous kinds; stratified log-rank (EXP-X4-3 KTD5) when censored; Cochran-Mantel-
  Haenszel for binary. Strata where either group has fewer than 2 units are excluded from
  the pooled test and listed under `strata_dropped` with flag `small_stratum_dropped`.
- **KTD4. Primary uses the stratified test when strata are declared.** The pooled
  stratified p replaces the unstratified p as the primary metric's p (and goes into Holm);
  the unstratified result is kept as `unstratified` for reference.
- **KTD5. Standardized effect.** Reweight both groups to the pooled stratum mix and take
  weighted medians; difference and ratio intervals by stratified bootstrap (resample
  within stratum, EXP-X4-1 U5).
- **KTD6. Composition shift.** Fisher/chi-square on the stratum × group table plus total
  variation distance; flag `composition_shift` when p < 0.05 or TVD > 0.2. The summary
  sentence says "stratum mix changed; standardized effect shown".
- **KTD7. Post-treatment warning.** If the spec names a stratum that the treatment could
  change (declared by X2's metric pack as `post_treatment: true`), the engine still runs
  but adds `stratum_may_be_affected_by_treatment`.

## Implementation Units

### U1. Stratified tests and standardized effect

**Files:** `analytics/lib/analytics/stats/strata.py`, `analytics/tests/test_stats_strata.py`,
goldens section for van Elteren (R `sanon` or hand-computed reference) and CMH
(statsmodels `StratifiedTable`).
**Test scenarios:**
- van Elteren statistic and p match the reference on 2 fixtures.
- CMH p matches statsmodels.
- Simpson fixture: each stratum shows no change; mix shifts toward complexity 1 in the
  after group; unstratified MWU says `significant improved`; stratified p is not
  significant, `composition_shift` set, standardized median difference interval spans 0.
- One stratum with 1 unit in group a → dropped and listed.

### U2. Driver and schema integration

**Files:** `analytics/lib/analytics/stats/analyze.py`, `analytics/schema/experiment-result.v1.json`
(`strata{}`, `stratified{}`, `unstratified{}`, `strata_dropped[]`, `composition{}`),
`analytics/lib/analytics/stats/summary_text.py`, `analytics/tests/test_stats_analyze.py`.
**Test scenarios:**
- Spec without strata → output identical to before this ticket.
- Missing complexity on 5 rows → `unknown` stratum with n 5.
- Primary metric with strata → Holm uses the stratified p (assert `p_raw` source field).

### U3. Methods page section

**Files:** `website/docs-app/reference/experiment-statistics.md`.
**Test expectation:** none -- docs.

## Verification Contract

Analytics CI green; Simpson fixture passes.

## Risks

- **Sparse strata at low volume.** Complexity 3 tickets are rare; dropping them is
  reported, and per-stratum guards keep small strata from producing claims.

## Definition of Done

Primary metrics with declared strata report a stratified p and standardized effect, and
composition shifts are flagged.

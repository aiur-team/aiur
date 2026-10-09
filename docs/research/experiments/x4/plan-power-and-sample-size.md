---
title: EXP-X4-5 Power, minimum detectable effect and samples needed - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x4/brainstorm.md
ticket: EXP-X4-5
complexity: 2
---

# EXP-X4-5 Power, minimum detectable effect and samples needed - Plan

## Summary

For each primary metric, estimate from the observed baseline distribution: power at the
current sample size for the pre-registered MDE, the MDE detectable at the power target,
units per group needed, the projected p-value if the observed effect holds, and the date
that sample size is reached at the current accrual rate. Set the `underpowered` flag.

## Problem Frame

Kevin: "anticipate the p-value based on how much data we have". The honest form of that
is prospective: how much data is needed to detect the effect we care about, when will we
have it, and what p would we expect then. Post-hoc "observed power" is not reported
(Hoenig and Heisey 2001): it is a function of the p-value and adds nothing.

## Requirements

Brainstorm R8, KD5.

## Key Technical Decisions

- **KTD1. Simulation from the baseline, not a normal model.** Durations are skewed and
  tied. Power at (n_a, n_b, shift) = fraction of S simulations where MWU two-sided p <
  alpha, with group a resampled from the baseline group and group b resampled from the
  baseline scaled by (1 − shift) for lower-is-better (multiplicative shift on the
  duration scale, i.e. a location shift on log scale). S = 1,000 by default; Monte Carlo
  SE reported.
- **KTD2. Samples needed** by bisection on n per group (allocation ratio taken from the
  current n_a:n_b) between 5 and 5,000; reports `> 5000` instead of extrapolating.
  Noether (1987) closed form is reported beside it as `samples_needed_noether` for a
  sanity check, using P(B<A) computed exactly from baseline vs shifted baseline.
- **KTD3. MDE at current n** by bisection on shift in [0, 0.9] at the power target.
- **KTD4. Projected p.** Median simulated p at the needed n under the *observed* shift,
  labelled `projected_p_if_effect_holds`. Shown as a projection, never as evidence.
- **KTD5. Accrual ETA.** Units per day in the after group over its window so far;
  `eta_date = snapshot.taken_at + (needed − current) / rate`. Omitted when rate is 0 or
  the window is under 24 h.
- **KTD6. Flags.** `underpowered` when power at current n < power target. For non-primary
  metrics only the cheap Noether estimate runs (cost control), flagged
  `power_estimate_approximate`.
- **KTD7. Censoring.** Power uses completed rows only and adds
  `power_ignores_censoring` when the metric is censored.
- **KTD8. Determinism.** Simulation seeds come from the same `seed_from` scheme with a
  `"power"` tag.

## Implementation Units

### U1. Power simulation and solvers

**Files:** `analytics/lib/analytics/stats/power.py`, `analytics/tests/test_stats_power.py`.
**Test scenarios:**
- Normal-baseline fixture: simulated power for d = 0.5, n 64/64, alpha 0.05 is 0.80 ±
  0.03 (the textbook value adjusted by the 0.955 MWU efficiency, ≈ n 67).
- Noether n for P = 0.64 matches the published closed-form value to the integer.
- Samples-needed bisection is monotone: needed n for MDE 0.3 ≤ needed n for MDE 0.2.
- Zero-variance baseline (all equal): returns `not_estimable` with a reason, no exception.
- Needed n above 5,000 reports `"> 5000"`.

### U2. Driver integration

**Files:** `analytics/lib/analytics/stats/analyze.py`, `analytics/schema/experiment-result.v1.json`
(`power{power_at_current_n, mde_at_current_n, samples_needed_per_group,
samples_needed_noether, projected_p_if_effect_holds, eta_date, simulations, mc_se}`),
`analytics/lib/analytics/stats/summary_text.py`, `analytics/tests/test_stats_analyze.py`.
**Approach:** Runs for primary metrics after the main analysis; runs even when the guard
fails (that is when the "how many more" answer matters most). The sentence for
`insufficient_data` and `inconclusive` appends "need about N per group to detect M%
(about D days at the current rate)".
**Test scenarios:**
- Insufficient-data fixture still gets `samples_needed_per_group` and `eta_date`.
- `underpowered` set for 2% shift at n 40; absent for 30% shift at n 40.
- Runtime: power for 3 primaries at n 200 under 20 s (assert with a generous bound).

### U3. Methods page section

**Files:** `website/docs-app/reference/experiment-statistics.md` (why no observed power;
how projections are computed).
**Test expectation:** none -- docs.

## Verification Contract

Analytics CI green; normal-baseline power check passes within its tolerance.

## Risks

- **Baseline unrepresentative** (e.g. the before window had an outage). The analyst
  (X6) annotates; the engine reports which group served as the baseline.
- **CPU.** Bounded by S and the bisection steps; primaries only.

## Definition of Done

Every primary metric result carries a `power` block and the "need about N" sentence.

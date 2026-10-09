---
title: EXP-X4-1 Stats core library - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x4/brainstorm.md
ticket: EXP-X4-1
complexity: 3
---

# EXP-X4-1 Stats core library - Plan

## Summary

Add a dependency-free (Python 3 stdlib) statistics package under
`analytics/lib/analytics/stats/` with the primitive estimators, tests and intervals the
experiment engine needs, each checked against SciPy/statsmodels golden values. No driver,
no schema, no CLI in this ticket (EXP-X4-2 owns those).

## Problem Frame

The analytics reducer has only a median/p95 helper (`analytics/lib/analytics/reduce.py:477-494`,
nearest-rank p95). The experiment engine needs rank tests, effect sizes, bootstrap
intervals and exact small-sample tests. The reducer is stdlib-only by contract
(`analytics/README.md`, "dependency-free"), so these must be written in pure Python and
proven correct against a reference implementation.

## Requirements

Advances brainstorm R1, R3, R4, R5, R12 (determinism), KD1, KD2, KD3.

## Key Technical Decisions

- **KTD1. Pure stdlib, golden-tested.** Reference values come from SciPy 1.14 /
  statsmodels 0.14, produced once by a generator script that is committed but not run in
  CI. CI runs only the stdlib tests against the committed JSON goldens.
- **KTD2. Own PRNG.** `stats/rng.py` implements PCG32 (O'Neill 2014) with a documented
  seed-from-bytes function (first 8 bytes of sha256 as state, next 8 as stream). A
  pinned test asserts the first 10 outputs for a fixed seed. `random.Random` is not used
  anywhere in `stats/`.
- **KTD3. One quantile definition.** Hyndman-Fan type 7 (linear interpolation, the R and
  NumPy default). Documented in the module docstring and the methods page.
- **KTD4. Exact where cheap, asymptotic otherwise, method always reported.** Every test
  returns `{statistic, p_value, method}` where `method` names the exact variant used
  (`exact`, `normal_tie_corrected`, `permutation_mc`), so the result is auditable.
- **KTD5. Special functions in-house.** Normal CDF/quantile via `statistics.NormalDist`;
  regularized incomplete gamma and beta (series + continued fraction, Numerical Recipes
  ch. 6) for chi-square, Poisson and binomial intervals. Tested at tails (1e-10).
- **KTD6. Bootstrap shares resamples.** One resample loop per (metric, stratum) computes
  every statistic passed to it, so median difference, median ratio and Cliff's delta
  intervals come from the same resamples and cost one loop.

## Implementation Units

### U1. PRNG and canonical numerics

**Goal:** Deterministic random stream and output rounding helpers.
**Files:** `analytics/lib/analytics/stats/__init__.py`, `analytics/lib/analytics/stats/rng.py`,
`analytics/lib/analytics/stats/numeric.py`, `analytics/tests/test_stats_rng.py`.
**Approach:** PCG32 with `next_u32`, `uniform()` (53-bit float from two draws),
`randbelow(n)` (rejection sampling, no modulo bias). `seed_from(*parts)` hashes
UTF-8-joined parts with sha256. `numeric.round_sig(x, 10)` and `fsum`-based mean.
**Test scenarios:**
- Fixed seed yields pinned first 10 `next_u32` values (guards against silent algorithm change).
- `randbelow(7)` over 70,000 draws: each bucket within 5% of 10,000 (chi-square sanity, p > 0.001).
- `seed_from("exp","m1")` differs from `seed_from("exp","m2")` and is stable across runs.
- `round_sig` of 0, negative, 1e-300, NaN, inf: NaN/inf rejected with a ValueError.

### U2. Descriptives

**Goal:** n, median, Q1, Q3, IQR, p90, min, max with type-7 quantiles.
**Files:** `analytics/lib/analytics/stats/describe.py`, `analytics/tests/test_stats_describe.py`.
**Test scenarios:**
- Matches `numpy.quantile(method="linear")` goldens for n = 1, 2, 3, 10, 101, with ties.
- Empty input returns `{"n": 0}` and no other keys (no division by zero).
- Values are not mutated (caller list order preserved).

### U3. Rank tests and rank effect sizes

**Goal:** Mann-Whitney U, Hodges-Lehmann shift with Moses interval, Cliff's delta.
**Files:** `analytics/lib/analytics/stats/ranks.py`, `analytics/tests/test_stats_ranks.py`,
`analytics/tests/fixtures/stats/goldens.json`.
**Approach:** Midranks for ties. Exact two-sided p by dynamic programming over the U
distribution when there are no ties and `n1*n2 <= 2500`; otherwise normal approximation
with tie correction and continuity correction (SciPy `method="asymptotic"` semantics).
`min_achievable_p(n1, n2)` returns `2 / C(n1+n2, n1)` for the guard in EXP-X4-2.
Hodges-Lehmann = median of all pairwise differences (B minus A); the Moses interval
inverts the U distribution (exact critical value when exact applies, normal otherwise).
Cliff's delta = (P(B>A) − P(B<A)), computed by a merge over sorted arrays in
O(n log n), with magnitude bands at 0.147 / 0.33 / 0.474.
**Test scenarios:**
- U and p match `scipy.stats.mannwhitneyu(..., alternative="two-sided", method="exact")`
  for 5 no-tie fixtures and `method="asymptotic"` for 5 tied fixtures, to 1e-9.
- Identical groups: p = 1.0, HL = 0, Cliff's delta = 0.
- Complete separation n 4 vs 4: p = 2/70.
- HL and Moses interval match R `wilcox.test(conf.int=TRUE)` goldens (stored in goldens.json).
- Cliff's delta on a fixture with ties equals the brute-force O(n²) count.
- One group empty: raises a ValueError naming the group (the driver guards before calling).

### U4. Permutation test

**Goal:** Two-sided Monte Carlo permutation test on a caller-supplied statistic.
**Files:** `analytics/lib/analytics/stats/permutation.py`, `analytics/tests/test_stats_permutation.py`.
**Approach:** Shuffle pooled labels with the PCG32 stream (Fisher-Yates); p =
(b + 1) / (m + 1) (Phipson and Smyth 2010); returns Monte Carlo standard error. Default
m = 20,000.
**Test scenarios:**
- Same seed twice gives the same p (bit-identical).
- Difference-in-medians on a 30% shifted fixture: p within 3 MC SE of SciPy
  `permutation_test` golden.
- Null fixture: p is never 0 (the +1 correction).

### U5. Bootstrap intervals

**Goal:** BCa and percentile intervals for one or more two-sample statistics.
**Files:** `analytics/lib/analytics/stats/bootstrap.py`, `analytics/tests/test_stats_bootstrap.py`.
**Approach:** Resample each group independently with replacement (optional strata map:
resample within each stratum). Acceleration from the two-sample jackknife. Returns
`{estimate, lo, hi, method, resamples, mc_se}` per statistic. Falls back to percentile
and reports `method: "percentile"` when the jackknife is degenerate (all jackknife values
equal, which happens for medians of tiny or tied samples).
**Test scenarios:**
- BCa interval for median difference matches `scipy.stats.bootstrap(method="BCa")`
  within Monte Carlo tolerance (endpoints within 2% of the range) on 3 fixtures.
- Degenerate jackknife fixture: method is `percentile`, no exception.
- Statistics list of 3 uses one resample loop (assert the statistic callables are each
  called exactly `resamples` times).

### U6. Binary and rate tests

**Goal:** Fisher exact test, Newcombe difference interval, conditional Poisson rate test
with exact rate-ratio interval.
**Files:** `analytics/lib/analytics/stats/counts.py`, `analytics/lib/analytics/stats/special.py`,
`analytics/tests/test_stats_counts.py`, `analytics/tests/test_stats_special.py`.
**Approach:** Fisher via hypergeometric with `math.comb` (two-sided by summing tables with
probability ≤ observed, relative tolerance 1e-7, SciPy semantics). Rate test: given k1
events over exposure t1 and k2 over t2, k1 ~ Binomial(k1+k2, t1/(t1+t2)); rate-ratio
interval from the Clopper-Pearson interval of that binomial (via incomplete beta).
**Test scenarios:**
- Fisher p matches `scipy.stats.fisher_exact` on 6 tables including zeros.
- Newcombe interval matches statsmodels `confint_proportions_2indep(method="newcomb")`.
- Rate test with 0 events in both groups: p = 1, ratio undefined, method states it.
- Incomplete gamma/beta match SciPy at 30 points including tails to 1e-10 relative.

### U7. Golden generator

**Goal:** Reproducible source for every golden value.
**Files:** `analytics/tests/fixtures/stats/generate_goldens.py`, `analytics/tests/fixtures/stats/goldens.json`,
`analytics/README.md` (one paragraph: goldens, how to regenerate, not run in CI).
**Test expectation:** none -- generator is a dev tool; its output is exercised by U2-U6 tests.

## Verification Contract

- `PYTHONPATH=analytics/lib python3 -m unittest discover -s analytics/tests -t analytics`
  passes in the existing `analytics` CI job (`.github/workflows/ci.yml:583-599`), with no
  new dependency.
- `grep -r "import numpy\|import scipy\|import random" analytics/lib/analytics/stats` is empty.

## Risks

- **Exact-DP cost.** `n1*n2 <= 2500` keeps the DP under ~10 ms; above that the normal
  approximation is accurate to well under 0.001 in p.
- **Golden drift.** If SciPy changes a default, regenerate deliberately; the generator
  pins versions in its header.

## Definition of Done

All units merged, CI `analytics` job green, every public function has a docstring that
names its method and reference.

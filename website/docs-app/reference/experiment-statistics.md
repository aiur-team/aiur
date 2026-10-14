# Experiment statistics

`analytics/experiment-stats` computes an offline, generic experiment result using Python 3's standard library. The pure facade is `analytics.stats.analyze(snapshot, spec, annotations)`. It reads no clock, network or environment. Metric names have no statistical meaning.

## Frozen inputs and CLI

```sh
analytics/experiment-stats --experiment-dir DIR
analytics/experiment-stats --experiment-dir DIR --check
analytics/experiment-stats --experiment-dir DIR --now 2026-10-09T00:00:00Z
```

The directory contains `spec.json`, `snapshot.json` and optional `annotations.json`. The CLI writes `result.json` atomically. `--check` recomputes and compares the entire stored body, including input hashes; an edited number returns exit 1 with a field-level JSON diff. Invalid input returns exit 2.

`--now` supplies an ISO8601 timestamp for `generated_at`, outside the computed body. It does not alter inference.

The snapshot has `experiment_id`, two ordered `groups` (baseline A, comparison B), and `metrics`, keyed by ID. Each entry supplies `kind` and `rows: [{unit_id, group, value, censored}]`. Rate entries instead supply `groups: {name: {events, exposure, n}}`, where `n` counts independent units, not events or exposure.

The spec supplies `metrics: [{id, direction, mde, unit, label}]`, `primary_metrics`, and optional analysis defaults. Kinds may also be in the spec. Flat X2 analysis rows with `metric` IDs are accepted when the spec supplies explicit kinds.

X2 exports currently reference pack definitions rather than embedding them: resolve that metadata before calling this driver. The CLI does not fetch packs or live data.

Numeric observations must be finite and nonnegative; binary values are 0 or 1. Unit IDs are unique within a metric. Unknown snapshot metrics are skipped with warnings. Directions are `lower_is_better` or `higher_is_better` (also X2's `decrease` and `increase`); `none` suppresses a direction claim.

## Methods and defaults

| Kind | Test and effect |
| --- | --- |
| duration, count | Two-sided Mann–Whitney U; seeded permutation sensitivity test; Hodges–Lehmann shift and Moses interval; Cliff's delta and bootstrap interval; BCa median difference and ratio intervals |
| binary | Two-sided Fisher exact; B minus A proportion difference and Newcombe interval |
| rate | Conditional exact Poisson test; exact B/A rate-ratio interval |
| bucketed | Count methods plus `autocorrelated_units`; independence may be violated |

Quantiles use Hyndman–Fan type 7. U is exact without ties up to nA × nB = 2500, otherwise normal with tie and continuity corrections. For small tied samples, the permutation p-value controls labels. The permutation contrast is the mean difference; p uses `(extreme + 1)/(resamples + 1)`.

Defaults: two-sided alpha 0.05, minimum 10 independent units per group, MDE 20% relative effect, power target 0.8 (recorded for later power analysis), 10,000 bootstrap draws for primaries, 2,000 for exploratory metrics, 20,000 permutations.

The spec can override `alpha`, `min_samples`, `power_target`, `bootstrap_primary`, `bootstrap_exploratory`, `permutation_resamples`; MDE is per metric. Intervals have 95% confidence. Bootstrap groups are drawn independently.

Degenerate jackknives fall back to percentile intervals; Monte Carlo standard error describes the bootstrap mean, not the interval endpoints. A zero-valued baseline observation makes the bootstrap ratio undefined; the driver reports the median difference and `relative_effect_undefined` instead.

Undefined or unbounded numbers serialize as null, never a plausible finite default. Each effect lists its unbounded fields separately. A one-sided unbounded interval can still establish direction when its finite endpoint excludes the null.

Censored durations are temporarily excluded with `censoring_ignored` and per-group censored counts. Censoring-aware inference, stratification and power estimation are separate follow-on methods; this driver does not claim them.

## Correction and labels

Pre-registered primaries use Holm correction. Other metrics use Benjamini–Hochberg and carry `exploratory`. An `added_at` later than the spec's `frozen_at` (or X2 `registered_at`) makes a listed primary exploratory, with a warning. With no primaries the overall result says “no pre-registered primary”.

Guarded hypotheses remain in the correction family as p=1 but report no test.

Either group below `min_samples` produces `insufficient_data`, descriptives only and `no_change`. Other statuses use the adjusted p: below alpha means `significant`; otherwise a relative-effect interval entirely within ±MDE means `practically_equivalent`; otherwise `inconclusive`.

Binary equivalence uses the baseline proportion to convert relative MDE into a proportion-difference margin. Undefined relative effects cannot establish equivalence. Direction is `improved` or `regressed` only when the interval excludes its null; otherwise `no_change`.

Statistical significance and direction remain separate fields. The untied minimum-achievable-p lower bound is reported for row metrics; `cannot_reach_significance` means even that bound exceeds alpha.

Annotations supply `flags: [{metric, flag, reason, author}]` (`metric: "*"` applies to all metrics) and `exclusions: [{unit_id, reason}]`. Analyst entries are copied verbatim. The engine never originates or removes `confounded`.

Exclusions change the sample count and appear in the numeric summary; aggregate rate evidence cannot support unit exclusions and is rejected if they are supplied. Every summary includes both sample sizes and descriptives. Every non-guarded summary includes the effect, CI, raw and adjusted p.

Overall statuses come only from primary metrics; flags are unioned without collapsing causes.

## Reproducibility

Result schema: `analytics/schema/experiment-result.v1.json`. The result body records the engine version and SHA256 hashes of full-precision input JSON (sorted keys, compact UTF-8 encoding). Seeds derive from experiment ID, metric ID, `pooled` and snapshot hash using the version-stable PCG32 generator.

Outputs use sorted keys, ten significant digits, UTF-8 and a trailing newline. Two identical inputs and engine versions produce identical bodies; timestamps are excluded from `--check`. Summaries use the published rounded numbers.
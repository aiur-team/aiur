# Experiment statistics

`analytics/experiment-stats` computes an offline, generic experiment result using Python 3's standard library. The pure facade is `analytics.stats.analyze(snapshot, spec, annotations)`. It reads no clock, network or environment. Metric names have no statistical meaning.

## Running it yourself

Aiur releases include `analytics/` beside `bin/` and `lib/`. From any working directory, run the release's tool against a frozen experiment directory:

```sh
/path/to/release/analytics/experiment-stats --experiment-dir /path/to/experiment
/path/to/release/analytics/experiment-stats --experiment-dir /path/to/experiment --check
```

Results live in that experiment's `result.json`; `--check` verifies its stored body without rewriting it. Python 3 must be on `PATH`. Missing Python makes daemon recomputation unavailable with `statistics unavailable: python3 not found`.

The daemon resolves tools in this order: explicit caller override, tracked repository checkout, bundled release, current directory. It logs the first resolved directory once. Its runner serializes recomputations, uses `nice -n 10` and kills the tool after 120 seconds; failures leave orchestration running. Callers decide when to request recomputation.

## Frozen inputs and CLI

```sh
analytics/experiment-stats --experiment-dir DIR
analytics/experiment-stats --experiment-dir DIR --check
analytics/experiment-stats --experiment-dir DIR --now 2026-10-09T00:00:00Z
```

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `--experiment-dir DIR` | Required directory containing the frozen experiment inputs. | `analytics/experiment-stats --experiment-dir ./frozen` |
| `--check` | Recomputes and compares the stored result body; exits 1 when it differs. | `analytics/experiment-stats --experiment-dir ./frozen --check` |
| `--now TIME` | Overrides the external `generated_at` timestamp without changing inference. | `analytics/experiment-stats --experiment-dir ./frozen --now 2026-10-09T00:00:00Z` |

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

Defaults: two-sided alpha 0.05, minimum 10 independent units per group, MDE 20% relative effect, power target 0.8, 10,000 bootstrap draws for primaries, 2,000 for exploratory metrics, 20,000 permutations.

The spec can override `alpha`, `min_samples`, `power_target`, `bootstrap_primary`, `bootstrap_exploratory`, `permutation_resamples`; MDE is per metric. Intervals have 95% confidence. Bootstrap groups are drawn independently.

Degenerate jackknives fall back to percentile intervals; Monte Carlo standard error describes the bootstrap mean, not the interval endpoints. A zero-valued baseline observation makes the bootstrap ratio undefined; the driver reports the median difference and `relative_effect_undefined` instead.

Undefined or unbounded numbers serialize as null, never a plausible finite default. Each effect lists its unbounded fields separately. A one-sided unbounded interval can still establish direction when its finite endpoint excludes the null.

### Censored durations

A duration row with `censored: true` is a unit still open at snapshot time; its `value` is the elapsed time so far. Dropping such rows keeps only the fast tickets of the younger window and flatters a new feature, so they are treated as right-censored instead.

When any row is censored the primary analysis changes:

- **Test and location.** The log-rank test gives `p_raw`; each group's median is the Kaplan-Meier median (first time survival reaches 0.5) with a Brookmeyer-Crowley interval from the log-log Greenwood variance, under `survival`. The completed-only rank test moves to `sensitivity`.
- **Equal follow-up.** Both groups are cut at the shorter group's longest follow-up; later rows are censored at that horizon (`survival.follow_up_horizon`, in the metric’s unit; flag `follow_up_truncated`).
- **Median difference.** Its 95% interval is the percentile interval of bootstrap Kaplan-Meier medians. If more than 10% of resamples reach no median, the interval is withheld.
- **Flags.** `censoring_heavy` means more than 20% of either group's rows are censored after truncation. `median_not_reached` means a group's curve never reaches 0.5, or the interval was withheld; the status is then at most `inconclusive` and the summary reports how much is still open.
- **Unknown start times.** A censored row with no `value` means the start time was unavailable. The metric falls back to completed-only inference and carries `censoring_unknown`. Declared stratification is also unavailable in this fallback (`stratification_unavailable`).

Metrics with no censored rows are analyzed exactly as before. Stratified metrics keep the pooled stratified log-rank described below, and `censoring_ignored` marks only the pooled placeholder there.

## Prospective power and accrual

Every metric carries a `power` block, including `insufficient_data` results. Primaries use 1,000 seeded empirical bootstrap simulations: A is resampled from completed baseline units, and B from that baseline multiplied by `1 − MDE` (or `1 + MDE` for higher-is-better).

Each simulation uses a two-sided MWU test with the same exact/tie/continuity rules as inference. `power_at_current_n` is the fraction below alpha; `mc_se` is its binomial Monte Carlo standard error. Censored units are excluded and flagged `power_ignores_censoring`.

`mde_at_current_n` searches shifts from 0 to 90% at the power target. `samples_needed_per_group` searches baseline n from 5 to 5,000, preserving the observed comparison/baseline allocation ratio (equal allocation when comparison is empty).

The comparison requirement is `ceil(n × allocation_ratio)`; the summary's per-group number is on the baseline scale. Requirements beyond the bound report `> 5000`; an unattainable MDE is null. Searches use common seeded draws and remain Monte Carlo estimates, not exact thresholds.

`samples_needed_noether` reports the Noether approximation beside the simulation: baseline n is `ceil((z(1−alpha/2)+z(target))² × (1+1/ratio) / (12 × (P−0.5)²))`, with a minimum of five. P is the exact empirical probability that B is below A, with half credit for ties.

See [Noether (1987)](https://doi.org/10.1080/01621459.1987.10478478). Exploratory metrics and per-stratum results run only this approximation and carry `power_estimate_approximate`.

With declared strata, primary power still models the pooled completed-only MWU test, while inference uses the stratified test. It carries `power_estimate_approximate`; the simulated estimate is not stratified power.

Empty or constant baselines return `not_estimable` with a reason and null estimates; binary and aggregate-rate tests also return `not_estimable`, since their tests require different prospective models. X2 analysis exports carry the observation time as `taken_at`.

`underpowered` compares prospective power at the registered MDE against the target. No post-hoc observed power is reported: it restates the observed p-value. `projected_p_if_effect_holds` is instead the median simulated p at the required n using the observed median ratio, explicitly a projection rather than evidence.

For ETA, supply snapshot `taken_at` and spec `windows[comparison].start` (or the A/B `observation` start). After at least 24 hours, completed comparison units divided by elapsed days gives `accrual_per_day`; remaining comparison units give `days_needed` and `eta_date`.

Frozen report inputs use the comparison snapshot window end as `taken_at`, keeping report hashes reproducible. Report rows map the nested power estimates into their power/MDE/sample columns; the numeric-only report sample field is null for `> 5000`, which remains explicit in the full engine result.

A zero rate, missing timestamps, or an unbounded requirement leaves ETA null. The computation uses only frozen inputs. Insufficient-data and inconclusive summaries append the requirement and, when available, the days at the current rate.

The daemon's `Aiur.Experiments.sample_status/1` reads arm evidence and returns completed-unit minimum-sample guards for primary metrics, including per-metric overrides. WindowManager uses these guards to end collection after the configured minimum window.

This guard is independent of the offline power target; unavailable coverage and empty primary sets cannot satisfy it.

## Stratification

Declare `strata: ["complexity"]` in a generic spec, or use X2's `stratify_by` (which defaults to complexity).

Omitting both preserves the unstratified result.

Fields select scalar values or tag lists in each row's `strata` object, with direct row attributes as fallback.

Null or missing values form an explicit `unknown` stratum.

A single nested tuple, such as `strata: [["complexity", "backend"]]`, explicitly crosses fields; multiple bare fields are rejected as ambiguous.

Tag lists are sorted into a canonical stratum; mixed types that would collide in a label are rejected.

Each stratum has its own minimum-sample guard and is always exploratory.

Benjamini–Hochberg adjusts the complete per-stratum family across metrics, including guarded hypotheses as p=1.

The pooled test drops strata with fewer than two units in either group, lists them in `strata_dropped`, and raises `small_stratum_dropped`.

The pooled minimum-sample guard uses only the retained population.

Uncensored row metrics use van Elteren's stratified Wilcoxon test, with tie-corrected variance and stratum weight 1/(nA+nB+1).

Binary metrics use Cochran–Mantel–Haenszel without continuity correction.

Censored durations use summed stratum log-rank scores and hypergeometric variances; tied events precede censoring.

These use a one-degree-of-freedom chi-square reference.

The stratified p is `p_raw`, marked by `p_raw_source: "stratified"`, and enters Holm for primary metrics.

`unstratified` retains the original tests, effects and raw p for reference.

Aggregate rate evidence has no per-unit strata; it keeps its original test and emits `stratification_unavailable` plus a warning.

Effects reweight both groups to the retained pooled stratum mixture: weighted median B−A and B/A for continuous metrics, weighted proportion B−A for binary metrics.

At an exact half-weight boundary, the weighted median averages adjacent observations.

A stratified bootstrap draws within each group and stratum at fixed mixture weights and reports 95% percentile intervals, draw count and Monte Carlo error.

These intervals explicitly use `percentile_stratified`, rather than BCa.

Censored standardized effects are unavailable (`standardized_effect_unavailable`); their log-rank p remains available, with no direction or equivalence claim.

Quantiles for a group containing censored rows are withheld; completed-only descriptives remain in `unstratified`.

`composition` compares the full nonexcluded stratum mix, including dropped strata: Fisher exact for two strata, Pearson chi-square for larger tables, plus total variation distance (TVD).

`composition_shift` means p < 0.05 or TVD > 0.2.

Missing groups produce null composition diagnostics.

Metric packs can supply `strata_metadata: {"field": {"post_treatment": true}}`.

X2 exports this as `metric_metadata[metric_ref].strata_metadata` alongside rows (generic resolved definitions may carry it directly); naming that field adds `stratum_may_be_affected_by_treatment` without suppressing inference.

## Correction and labels

Pre-registered primaries use Holm correction at `alpha`. Other metrics use Benjamini–Hochberg at `fdr_q` (defaults to `alpha`) and carry `exploratory`. An `added_at` later than the spec's `frozen_at` (or X2 `registered_at`) makes a listed primary exploratory, with a warning. With no primaries the overall result says “no pre-registered primary”.

Guarded hypotheses remain in the correction family as p=1 but report no test.

Either group below `min_samples` produces `insufficient_data`, descriptives and prospective power only, and `no_change`. Other statuses use the adjusted p: below alpha means `significant`; otherwise a relative-effect interval entirely within ±MDE means `practically_equivalent`; otherwise `inconclusive`.

Binary equivalence uses the baseline proportion to convert relative MDE into a proportion-difference margin. Undefined relative effects cannot establish equivalence. Direction is `improved` or `regressed` only when the interval excludes its null; otherwise `no_change`.

Statistical significance and direction remain separate fields. The untied minimum-achievable-p lower bound is reported for row metrics; `cannot_reach_significance` means even that bound exceeds alpha.

Annotations supply `flags: [{metric, flag, reason, author}]` (`metric: "*"` applies to all metrics) and `exclusions: [{unit_id, reason}]`. Analyst entries are copied verbatim. The engine never originates or removes `confounded`.

Exclusions change the sample count and appear in the numeric summary; aggregate rate evidence cannot support unit exclusions and is rejected if they are supplied. Every summary includes both sample sizes and descriptives. Every non-guarded summary includes the effect, CI, raw and adjusted p.

Overall statuses come only from primary metrics; flags are unioned without collapsing causes.

## Reproducibility

Result schema: `analytics/schema/experiment-result.v1.json`. The result body records the engine version and SHA256 hashes of full-precision input JSON (sorted keys, compact UTF-8 encoding). Seeds derive from experiment ID, metric ID, `pooled` and snapshot hash using the version-stable PCG32 generator.

Outputs use sorted keys, ten significant digits, UTF-8 and a trailing newline. Two identical inputs and engine versions produce identical bodies; timestamps are excluded from `--check`. Summaries use the published rounded numbers.


## Reports and labels

Register with `aiur experiments preregister <id> --file prereg.json`. The server assigns time and `post_hoc` after results reads. Repeating registration requires a JSON `reason`; amendments preserve the original and flag post-hoc changes. Contracts: `src/priv/experiments/schema/`.

Labels, weakest first: `not-enough-data`, `underpowered`, `inconclusive`, `no-effect-detected`, `significant`. An analyst may weaken engine labels with a reason, never strengthen them. Overall labels derive from primaries; chips show n, effect and CI, with unavailable values explicit.

Every event ID appears once. High/`noted` confounders require `confounded`; sensitivity needs a linked analysis. Snapshot hashes and registration must match. Summary verdicts need numbers; below planned n, confirmatory becomes interim.

After freezing both windows and collecting events, `aiur experiments stats <id> --json` returns the input hash and report-ready rows. `aiur experiments report submit <id> --file report.json` recomputes those inputs, rejects stale or invented numbers, and stores the next version. `show --json` exposes the report history.

## The analyst skill

The [aiur-experiment analyst](/skills#agent-workspace-skills) ships to every workspace. Spec mode registers blind hypotheses and pack metrics; report mode interprets engine statistics. Analysis tickets publish through the validated CLI, verify persistence and finish without a PR.

Register with `aiur experiments preregister <id> --file prereg.json`. The server sets time and post-hoc status; amendments need `reason` and retain originals. Spec stops without a baseline-only read and X4 power plan: current `show` can expose outcomes and `stats` has no planning or exclusion flags. Contracts live in `src/priv/experiments/schema/`.

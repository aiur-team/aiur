---
title: Experiments stats engine (X4) - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
date: 2026-10-09
area: EXP-X4
epic: aiur-team/aiur#3774
---

# Experiments stats engine (X4) - Plan

## Goal Capsule

- **Objective.** Give every experiment (before/after line or A/B cohorts) a statistics
  result that a data scientist would accept: medians with spread and counts, a
  "not enough data" guard, same-complexity comparison, effect sizes with confidence
  intervals, nonparametric p-values, power and "samples needed", multiple-comparison
  correction, correct treatment of tickets that are still open, and machine-readable
  labels. Results must be reproducible byte-for-byte from a frozen snapshot.
- **Product authority.** Operator brainstorm 2026-10-09 (`../requirements.md`, the brief
  for epic #3774). Settled there: verdict rigor (medians + spread + counts, "not enough
  data", same-complexity comparison, no bare verdict word), the analyst wants
  "anticipate the p-value based on how much data we have" and data-science labels,
  generic metrics (built-in pack, not hard-coded), MP-R1 modularity.
- **Open blockers.** None for X4 itself. X4 depends on two interfaces from other areas
  (named in "Assumed interfaces"): the X2 snapshot must keep per-unit observations, and
  X1 must record the start time of tickets that are still open.

## Product Contract

### Actors

- **Analyst agent (X6).** Runs the engine, reads the result, writes the report, adds
  confounder annotations, re-runs.
- **Experiments page (X5).** Renders result numbers, labels and summary sentences.
- **Operator (Kevin) and consumer-repo users.** Read the page; may hand-run the CLI.
- **Daemon.** Triggers recomputation (fail-open); never computes statistics itself.

### Requirements

R1. **Descriptives per group, per metric, per stratum.** n, n censored, median, Q1, Q3,
IQR, p90, min, max. Quantiles use one documented definition (Hyndman-Fan type 7, the R
and NumPy default) everywhere.

R2. **Minimum-sample guard.** Below `min_samples` units in either group (default 10,
spec-overridable) the metric is `insufficient_data`: descriptives are shown, no test,
no interval, no direction claim. The engine also reports the smallest p-value the
observed sizes can reach, and flags `cannot_reach_significance` when it exceeds alpha.

R3. **Effect sizes with intervals.** For continuous metrics: difference of medians and
ratio of medians (the "X% faster" number), each with a 95% bootstrap interval;
Hodges-Lehmann shift with its rank-inversion (Moses) interval; Cliff's delta with an
interval and a magnitude band (negligible / small / medium / large, Romano et al. 2006
thresholds). Binary metrics: difference of proportions with a Newcombe interval. Rate
metrics: rate ratio with an exact interval.

R4. **Nonparametric tests.** Two-sided Mann-Whitney U (exact when there are no ties and
the samples are small, normal approximation with tie and continuity correction
otherwise); a seeded Monte Carlo permutation test as the robustness check and as the
small-sample method when ties exist; Fisher exact for binary; conditional binomial exact
test for event rates per exposure. Two-sided always; the pre-registered expected
direction sets the `improved` / `regressed` wording, not a one-sided test.

R5. **Bootstrap intervals.** BCa (bias-corrected and accelerated) intervals, resampling
each group independently (and within strata when stratified), with the resample count
and Monte Carlo error reported.

R6. **Right-censored durations.** A ticket started but not merged at snapshot time
contributes "at least this long", never nothing. When either group has censored units:
Kaplan-Meier medians with intervals, log-rank p-value (stratified when strata exist),
and both groups truncated at the same follow-up horizon so the newer "after" window is
not flattered by short follow-up. The completed-only Mann-Whitney result is still
reported as a sensitivity analysis. Flags: `censoring_heavy` (more than 20% censored),
`median_not_reached`.

R7. **Stratification.** Default stratum is ticket complexity; the spec may name others
(backend, model, consumer tags). Per-stratum results each carry their own guard. A
pooled stratified answer uses the van Elteren test (stratified Wilcoxon) or stratified
log-rank, and a composition-standardized median difference. A change in stratum mix
between groups raises `composition_shift` (Simpson's-paradox risk). Strata too small to
test are dropped from the pooled test and listed.

R8. **Power, MDE, samples needed, projected p.** For each primary metric, computed from
the observed baseline distribution (not a normal assumption): power at the current n for
the pre-registered minimum detectable effect (MDE, default 20% median shift), the MDE at
80% power for the current n, units per group needed for the pre-registered MDE, the
projected p-value if the observed effect holds at the needed n, and the estimated date
that n is reached at the current accrual rate. Power uses the pre-registered MDE, never
the observed effect ("observed power" is not reported; Hoenig and Heisey 2001). Flag:
`underpowered` when power at current n is below the target (default 0.8).

R9. **Multiple comparisons.** Primary metrics (pre-registered in the spec): Holm
correction. Every other metric and every per-stratum result: Benjamini-Hochberg q-values
and the `exploratory` flag. Raw and adjusted values are both reported; labels use the
adjusted value. With no pre-registered primary, every metric is exploratory and the
result says so.

R10. **Labels.** One `status` per metric result: `insufficient_data`, `inconclusive`,
`significant`, `practically_equivalent` (not significant, and the whole interval lies
inside plus-or-minus the MDE). One `direction`: `improved`, `regressed`, `no_change`.
Zero or more `flags`: computed ones (R2, R6, R7, R8, R9, `ties_heavy`,
`autocorrelated_units`) and analyst-supplied ones (`confounded` and free-text reasons,
carried from the annotations file unchanged). The engine never sets `confounded` and
never removes it.

R11. **No bare verdict word.** Every result carries a deterministic summary sentence that
always contains the numbers behind the label, e.g. "start to merge: median 3.1 h to
2.4 h (-23%, 95% CI -35% to -8%), n 42 vs 37, p 0.004 (Holm 0.012); significant
improvement; flags: none." The page and the analyst quote it rather than composing
their own.

R12. **Reproducible.** The engine is a pure function of (snapshot, spec, annotations,
engine version). No clock, no network, no environment reads in the computed part. Seeds
are derived from content hashes. The result records input hashes and engine version. A
`--check` mode recomputes and fails on any byte difference.

R13. **Generic.** The engine knows metric *kinds*, not metric names: `duration`
(censorable), `count` (per-unit, tie-heavy), `binary`, `rate` (events over exposure),
`bucketed` (one value per day or hour). Metric packs (X2) declare the kind. Nothing in
the engine names an Aiur metric.

R14. **Runs for consumer repos.** The engine ships with the Aiur release, not only in
the Aiur source checkout.

### Out of scope

- Choosing metrics, windows or primaries (X2 spec, X6 analyst).
- Detecting confounders (X6 analyst; the engine only carries them).
- Rendering charts (X5).
- Bayesian analysis, sequential testing with alpha spending, regression adjustment
  beyond stratification. Recorded as later options, not needed for the first experiment.

### Key decisions

**KD1. Where it runs: Python, in `analytics/`, stdlib only. The daemon never computes
statistics.** Reasons:
1. The analytics contract already says "one reducer, one schema, two readers"
   (`analytics/README.md`): Python reduces, Elixir reads JSON. A stats engine is a
   second reducer stage over the same data; putting it in Elixir would create a second
   source of truth.
2. Reproducibility from a frozen snapshot is a property of an offline, pure tool. The
   analyst agent, CI and a data scientist on any machine can rerun it with
   `python3`; an in-daemon engine needs a running daemon.
3. Bootstrap and power simulation are CPU-heavy (tens of thousands of resamples per
   metric). On the BEAM they compete with the schedulers that run the fleet; as a
   subprocess they run with a timeout and fail open, as `analytics/reduce` does today
   (`src/lib/aiur/run_telemetry/summaries.ex:103-160`), and additionally under `nice`.
4. Auditability: data scientists read Python. Golden values are cross-checked against
   SciPy offline and committed as fixtures, so the test suite stays stdlib-only and runs
   in the existing `analytics` CI job (`.github/workflows/ci.yml:583-599`).
5. Precedent for a python3 runtime dependency already exists (`src/priv/github_budget.py`,
   `src/priv/build_gate_holder.py`), with a fail-open path when python3 is absent.

Rejected: Elixir in-daemon (no stats library in deps, would need Nx/Explorer or
hand-rolled code anyway, blocks reproducibility outside the daemon); NumPy/SciPy
(adds a dependency the reducer has deliberately avoided, and a consumer host may not
have it).

**KD2. Own PRNG.** The engine uses its own small deterministic generator (PCG32 or
xoshiro256**), not `random.Random`, so a Python upgrade cannot change a published
result. Seeds come from sha256(experiment id, metric id, stratum, snapshot hash).

**KD3. Canonical output.** Sorted keys, floats rounded to 10 significant digits,
`math.fsum` for sums. This makes results byte-stable across platforms whose `libm`
differs in the last bit.

**KD4. Censoring changes the primary method, not just a flag.** Dropping open tickets
biases the "after" window toward fast tickets, because it has had less time. That is the
exact failure mode of a new feature's first week, so it is handled by default.

**KD5. Defaults:** alpha 0.05 two-sided, power target 0.8, MDE 20% relative median
shift, `min_samples` 10 per group, 10,000 bootstrap resamples for primary metrics and
2,000 for exploratory ones. All spec-overridable; defaults are recorded in the result.

**KD6. Labels are a fixed vocabulary** (R10) published in the result schema, so X5 can
style them and X6 can reason over them without parsing prose.

**KD7. MP-R1 fit.** The engine is one leaf component, `experiment-stats`
(kind `package`, non-runtime like `listener-spec`), with no dependencies and one facade:
the `analytics.stats.analyze(snapshot, spec, annotations)` function and the
`analytics/experiment-stats` CLI. The Elixir `experiments` component (X2) reaches it only
through a thin runner port that shells out and reads the result file.

### Assumed interfaces from other areas

- **X2 snapshot** (`snapshot.json`) keeps **per-unit observations**, not just summary
  statistics: for each metric, rows of `{unit_id, group, value, censored, strata{...},
  observed_at}`. Without per-unit rows no test or interval is possible. A frozen
  baseline that only stores medians is not enough. Small (hundreds of rows).
- **X2 spec** carries: `groups` (before/after or cohort names), `metrics[]` with
  `{id, kind, direction (lower_is_better|higher_is_better), mde (relative), unit}`,
  `primary_metrics[]`, `alpha`, `power_target`, `min_samples`, `strata[]`, `frozen_at`.
  Metrics added after `frozen_at` are exploratory regardless of the primary list.
- **X2 store:** `<state-node>/experiments/<id>/{spec.json, snapshot.json,
  annotations.json, result.json}`. X4 writes only `result.json`.
- **X1 capture:** complexity at dispatch (exists: `analytics/lib/analytics/reduce.py:582`,
  `:636-640`), and a start timestamp plus still-open status for each unfinished ticket at
  snapshot time (needed for censoring), plus PR-open timestamps that are not taken from
  `merged_at` (`reduce.py:366-368`).
- **X5 page:** renders `summary_text`, `status`, `direction`, `flags`, numbers; never a
  label without its sentence.
- **X6 analyst:** writes `annotations.json` (`confounded` flags with reasons, unit
  exclusions with reasons), reruns, quotes `summary_text`, uses `--check`.
- **X3 auto experiments:** no human pre-registration, so the default primary is the
  built-in pack's start-to-merge duration; everything else is exploratory.

### Verified facts

- `analytics/reduce` is resolved only from the tracked repo's base checkout or the
  current directory (`src/lib/aiur/run_telemetry/summaries.ex:183-190`), and the release
  steps are `[:assemble, &copy_cli_launcher/1]` (`src/mix.exs:202`). A consumer repo
  therefore has no `analytics/` today. R14 needs the release to ship it.
- The reducer is stdlib-only and already has a `_statistics` helper with a median and a
  nearest-rank p95 (`reduce.py:477-494`); the engine does not reuse it (different
  quantile definition) and documents the difference.
- `components.json` exists on main with a `telemetry` component covering
  `src/lib/aiur/run_telemetry/**`; nothing covers `analytics/`.

### Success criteria

- On the committed fixtures, every statistic matches SciPy/statsmodels/lifelines golden
  values to 1e-6 (p-values, HL, KM medians) or to the documented Monte Carlo tolerance.
- Running `--check` twice on the same inputs gives identical bytes; a different Python
  minor version gives identical bytes on the fixture.
- On a synthetic snapshot with a known 30% shift and n 40 per group, the result is
  `significant` / `improved`; at n 6 it is `insufficient_data`; with a 2% shift and n 40
  it is `inconclusive` + `underpowered`; with heavy censoring in the after group only,
  completed-only analysis and KM analysis disagree and the KM one is primary.
- The full default pack (about 15 metrics, 4 strata, n 200 per group) completes in under
  60 s on a CI runner.

### Open questions for Kevin

1. Default `min_samples` 10 per group? (Recommend 10: below it the IQR and bootstrap are
   not trustworthy; at current fleet throughput 10 merges per window is one to two days.)
2. Default MDE 20% median shift and power 0.8? (Recommend yes; a smaller MDE needs
   hundreds of tickets per group with the current spread.)
3. Default primary metric for auto-created experiments: start-to-merge median?
   (Recommend yes; a single primary keeps Holm cheap and the verdict readable.)

## Ticket plans

| Ticket | Plan | Blocked by |
|---|---|---|
| EXP-X4-1 Stats core library | [plan-stats-core.md](plan-stats-core.md) | — |
| EXP-X4-2 Analysis driver, result schema, CLI | [plan-analysis-driver.md](plan-analysis-driver.md) | X4-1 |
| EXP-X4-3 Right-censored durations | [plan-censored-durations.md](plan-censored-durations.md) | X4-2 |
| EXP-X4-4 Stratification | [plan-stratification.md](plan-stratification.md) | X4-2 |
| EXP-X4-5 Power and samples needed | [plan-power-and-sample-size.md](plan-power-and-sample-size.md) | X4-2 |
| EXP-X4-6 Release packaging and runner port | [plan-runtime-packaging.md](plan-runtime-packaging.md) | X4-2 |

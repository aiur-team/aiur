---
title: EXP-X4-2 Experiment analysis driver, result schema and CLI - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x4/brainstorm.md
ticket: EXP-X4-2
complexity: 3
---

# EXP-X4-2 Experiment analysis driver, result schema and CLI - Plan

## Summary

Add the pure function `analyze(snapshot, spec, annotations) -> result`, the
`experiment-result.v1.json` schema, the multiple-comparison step, the label rules, the
deterministic summary sentence, and the `analytics/experiment-stats` CLI with a
`--check` reproducibility mode. This is the engine's single facade.

## Problem Frame

EXP-X4-1 gives primitives. Something must choose the method per metric kind, apply the
minimum-sample guard, correct for many metrics, assign labels from a fixed vocabulary,
write a sentence that always carries its numbers (brief: "no bare verdict word"), and do
it byte-identically from a frozen snapshot.

## Requirements

Brainstorm R1, R2, R3, R4, R9, R10, R11, R12, R13; KD3, KD5, KD6, KD7.

## Assumed interfaces (other areas)

- X2 `snapshot.json`: `{schema_version, experiment_id, groups:[a,b], metrics:{<id>:
  {kind, rows:[{unit_id, group, value, censored, strata:{}, observed_at}]}}, exposure?}`.
  Rate metrics carry `{events, exposure}` per group instead of rows.
- X2 `spec.json`: `metrics[{id, kind, direction, mde, unit, label}]`, `primary_metrics`,
  `alpha`, `power_target`, `min_samples`, `strata`, `frozen_at`.
- X6 `annotations.json`: `{flags:[{metric|"*", flag, reason, author}], exclusions:[{unit_id, reason}]}`.
If X2 lands different field names, a small adapter in `analytics/lib/analytics/stats/inputs.py`
maps them; the engine core does not change.

## Key Technical Decisions

- **KTD1. Method by kind** (KD from R13): `duration` and `count` → descriptives, MWU,
  permutation (robustness), HL+Moses, Cliff's delta, BCa intervals for median difference
  and median ratio. `binary` → Fisher + Newcombe. `rate` → conditional Poisson + exact
  ratio interval. `bucketed` → same as `count` plus the `autocorrelated_units` flag.
  `duration` with any censored row is handed to EXP-X4-3's path once it lands; until then
  censored rows are excluded and the result carries `censoring_ignored` (temporary flag,
  removed by EXP-X4-3).
- **KTD2. Guard before compute.** Either group below `min_samples` → status
  `insufficient_data`, descriptives only. `min_achievable_p > alpha` → flag
  `cannot_reach_significance`.
- **KTD3. Multiplicity.** Holm over primary metrics' pooled p-values; Benjamini-Hochberg
  over everything else (secondary metrics and every per-stratum result). Metrics added to
  the spec after `frozen_at`, or not in `primary_metrics`, are `exploratory`.
- **KTD4. Status rules** (evaluated in order, adjusted p):
  1. guard fails → `insufficient_data`;
  2. p_adj < alpha → `significant`;
  3. interval for the relative effect lies entirely within ±MDE → `practically_equivalent`;
  4. otherwise `inconclusive`.
  Direction from the sign of the point estimate relative to `direction`, `no_change` when
  the interval spans zero. Analyst flags are copied, never interpreted, except that the
  summary sentence appends "(analyst: confounded — <reason>)".
- **KTD5. Overall verdict** is derived from primary metrics only and is a list of their
  statuses plus the union of flags; no single collapsed word.
- **KTD6. Determinism.** Seeds = `seed_from(experiment_id, metric_id, stratum,
  snapshot_sha256)`. Output JSON: sorted keys, `round_sig(10)`, `ensure_ascii=False`,
  trailing newline. `generated_at` lives outside the hashed `body`; `--check` compares
  `body` only. Result records `inputs:{snapshot_sha256, spec_sha256, annotations_sha256}`
  and `engine:{name:"experiment-stats", version}`.
- **KTD7. Exclusions are visible.** Units excluded by annotations are removed before
  analysis and listed with reasons and counts per group; the sentence mentions
  "k units excluded".

## Implementation Units

### U1. Result schema

**Files:** `analytics/schema/experiment-result.v1.json`, `analytics/tests/test_experiment_schema.py`.
**Approach:** JSON Schema draft 2020-12 with enums for `status`, `direction`, `flags`
(computed + `confounded` + free analyst flags under `analyst_flags`). Per metric:
`groups{a,b}{descriptives}`, `effects{}`, `tests{}`, `p_raw`, `p_adj`, `adjustment`,
`status`, `direction`, `flags`, `summary_text`, `strata{}` (filled by EXP-X4-4),
`power{}` (filled by EXP-X4-5). Fields for later tickets are optional.
**Test scenarios:**
- A hand-written minimal valid result passes a small structural checker in the test
  (no jsonschema dependency; the analytics suite is stdlib-only).
- An unknown `status` value fails validation.

### U2. Inputs and driver

**Files:** `analytics/lib/analytics/stats/inputs.py`, `analytics/lib/analytics/stats/analyze.py`,
`analytics/tests/test_stats_analyze.py`, `analytics/tests/fixtures/stats/experiments/*.json`.
**Approach:** Validate and normalize inputs (reject NaN, negative durations, unknown kind,
group names not in spec). Apply exclusions. Dispatch per kind (KTD1). Collect p-values,
run KTD3, then KTD4, then summary text.
**Test scenarios:**
- 30% shift, n 40/40, duration kind → `significant`, `improved` (lower_is_better).
- Same with `higher_is_better` → `regressed`.
- n 6/40 → `insufficient_data`, no `tests` key, descriptives present.
- 2% shift, n 40/40, MDE 20% → `inconclusive` or `practically_equivalent` depending on
  interval; fixture pinned for each.
- Binary and rate fixtures produce Fisher / conditional-Poisson methods.
- Exclusion of 3 units changes n by 3 and appears in `exclusions` and in the sentence.
- Snapshot with a metric not in spec → warning in `warnings[]`, metric skipped.

### U3. Multiplicity

**Files:** `analytics/lib/analytics/stats/multiplicity.py`, `analytics/tests/test_stats_multiplicity.py`.
**Test scenarios:**
- Holm and BH match `statsmodels.stats.multitest.multipletests` goldens (incl. ties, p=1).
- Spec with no primaries → every metric BH + `exploratory`, overall verdict says
  "no pre-registered primary".
- Metric added after `frozen_at` but listed as primary → treated as exploratory, warning emitted.

### U4. Summary sentence

**Files:** `analytics/lib/analytics/stats/summary_text.py`, `analytics/tests/test_stats_summary_text.py`.
**Approach:** Template per kind and status; numbers formatted with units from the spec
(`h`, `min`, `%`, count). Every status, including `insufficient_data`, includes n per
group; non-guarded statuses include the effect, its interval, raw and adjusted p.
**Test scenarios:**
- For each status, the sentence contains n for both groups (regex), and for non-guard
  statuses contains "CI" and "p".
- Confounded annotation appears verbatim with reason.
- Durations under 1 h print in minutes; over 48 h in days.

### U5. CLI and reproducibility check

**Files:** `analytics/experiment-stats` (bash wrapper like `analytics/run-summary`),
`analytics/lib/analytics/experiment_stats_cmd.py`, `analytics/tests/test_experiment_stats_cmd.py`,
`analytics/README.md` (tools table row).
**Approach:** `experiment-stats --experiment-dir DIR` reads `spec.json`, `snapshot.json`,
optional `annotations.json`, writes `result.json` atomically (reuse the reducer's
atomic-write pattern, `reduce.py:961`). `--check` recomputes and exits 1 with a unified
diff when `body` differs. `--now` overrides `generated_at`. Exit 2 on invalid input.
**Test scenarios:**
- Two runs produce byte-identical `body`.
- `--check` after hand-editing one number exits 1 and prints the path of the changed field.
- Missing `annotations.json` is fine; malformed one exits 2 with the parse error.

### U6. Methods documentation page

**Files:** `website/docs-app/reference/experiment-statistics.md`,
`website/docs-app/.vitepress/config.ts` (Reference sidebar entry).
**Approach:** One page a data scientist can audit: per kind the method, the quantile
definition, defaults (alpha, power, MDE, min_samples, resamples), the label rules, the
reproducibility contract and `--check`. Later tickets add their sections.
**Test expectation:** none -- docs; the website build validates links.

## Verification Contract

Analytics CI job green; `--check` passes on every committed experiment fixture; the
methods page builds.

## Risks

- **Interface drift with X2.** Mitigated by `inputs.py` adapter and fixtures that mirror
  X2's schema once it lands.
- **Over-reporting.** Many metrics × strata invite false positives; BH plus the
  `exploratory` flag and the primary-only overall verdict contain this.

## Definition of Done

`analytics/experiment-stats` runs on a fixture experiment directory, writes a valid
`result.json`, `--check` passes, and the methods page is in the sidebar.

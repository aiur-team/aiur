---
title: EXP-X6-3 - Pre-registration and report contract, template, submit and validate - Plan
date: 2026-10-09
area: EXP-X6
ticket: EXP-X6-3
complexity: 2
brainstorm: docs/research/experiments/x6/brainstorm.md
---

# EXP-X6-3 - Pre-registration and report contract

## Outcome

Two versioned JSON contracts (`preregistration.v1`, `report.v1`), one
Markdown rendering template, and two CLI verbs that validate and store them:

```
aiur experiments preregister <id> --file prereg.json [--json]
aiur experiments report submit <id> --file report.json [--json]
```

The page (X5) renders `report.v1`; the skill (EXP-X6-1) writes it. This ticket
is the single owner of the shape, so the two cannot drift.

## Component boundary (MP-R1)

New code belongs to the `experiments` component that X2 creates (in-app,
facade `Aiur.Experiments`). Files added here:

- `src/priv/experiments/schema/preregistration.v1.json`
- `src/priv/experiments/schema/report.v1.json`
- `src/lib/aiur/experiments/report_contract.ex` (validation, pure functions)
- `src/lib/aiur/experiments/report_markdown.ex` (render `report.v1` to Markdown
  for CLI output and for the ticket workpad)
- CLI verbs in `src/lib/aiur/experiments_cli.ex` (created by X2; add verbs
  only) and their control entry beside `build_orders/1` and `analytics/1` in
  `src/lib/aiur/agent_control_cli.ex:371-379` (origin/main 1c4409e43).

Writes go only through the X2 facade (`put_preregistration/2`,
`put_report/2`). This module never touches paths.

## preregistration.v1

```json
{
  "schema_version": "preregistration.v1",
  "experiment_id": "exp-optimistic-start-3755",
  "registered_at": "2026-10-09T18:00:00Z",
  "registered_by": {"role": "analyst", "agent": "claude", "model": "...", "ticket": 3801},
  "hypothesis": "Starting dependents when the blocker PR is approved, not merged, lowers blocker-merge to dependent-start time.",
  "primary_metrics": [{"id": "delivery.blocker_merge_to_dependent_start", "expected": "decrease"}],
  "secondary_metrics": [{"id": "delivery.start_to_merge", "expected": "decrease"},
                        {"id": "quality.reverts_per_merged", "expected": "no-change"}],
  "guardrail_metrics": [{"id": "quality.main_red_events", "expected": "no-increase"}],
  "alpha": 0.05,
  "secondary_correction": "benjamini-hochberg",
  "fdr_q": 0.10,
  "mde": {"metric": "delivery.blocker_merge_to_dependent_start", "relative": -0.20},
  "power_target": 0.80,
  "planned_n_per_cohort": 40,
  "projected_ready_at": "2026-10-23",
  "stratify_by": ["complexity"],
  "exclusions": ["tickets with a human:todo hold longer than 24h"],
  "stopping_rule": "one confirmatory analysis at planned_n_per_cohort; interim reports are descriptive",
  "baseline_snapshot_hash": "sha256:...",
  "post_hoc": false,
  "amendments": []
}
```

Rules:

- `post_hoc` is set by the server, not the author: true when
  `registered_at` is after the store's `first_results_read_at` (X2
  `record_results_read/1`). The author's value is ignored.
- A second `preregister` call after one exists is an **amendment**: it is
  appended to `amendments[]` with `reason` (required) and `at`; the original
  stays. Amendments after `first_results_read_at` are flagged and shown.
- `planned_n_per_cohort` and `projected_ready_at` must come from the X4 power
  calculation on the frozen baseline (the skill tells the analyst how).

## report.v1

Top-level sections, in render order. Every section is required; an empty one
states why (for example "no cohorts: line experiment").

| Key | Content |
|---|---|
| `header` | experiment id, title, `report_version` (server-assigned, monotone), `analysis_type` (`interim` or `confirmatory`), `generated_at`, analyst (role, agent, model, ticket or `executor`), `stats_snapshot_hash`, `events_snapshot_hash`, `preregistration_hash` |
| `summary` | 3-6 sentences. Each claim carries a number. No bare verdict word (validator rejects a summary that contains a label word without a number in the same sentence). |
| `preregistration` | copy of the registered record plus `deviations[]` (what the analysis did differently, and why) |
| `design` | `kind` (`line` or `cohorts`), windows, cohort definitions, unit of analysis, inclusion and exclusion counts with reasons, strata |
| `sample` | n per cohort per stratum; excluded n per reason; balance: complexity mix, backend/model mix, ticket-size mix per cohort with standardized differences; SRM chi-square p for cohort experiments with a planned split |
| `results[]` | one row per metric: `metric`, `role` (`primary`, `secondary`, `guardrail`, `exploratory`), `unit`, per-cohort `n`, `median`, `iqr`, `effect` (`kind`: median difference or ratio, `value`), `ci95`, `p`, `p_adjusted`, `family`, `power_at_mde`, `mde_at_n`, `n_needed_per_cohort`, `engine_label`, `label`, `label_reason`, `direction` (`as-expected`, `opposite`, `none`) |
| `confounders[]` | ledger row per collected event: `event_id`, `kind`, `at` or `[from, to]`, `ref` (PR, release, alert id), `title`, `classification` (`treatment`, `bug-fix`, `unrelated-change`, `config`, `release`, `incident`, `outage`, `main-red`, `capacity`), `affects[]` (metric ids), `bias` (`inflates`, `deflates`, `unknown`), `severity` (`none`, `low`, `high`), `handling` (`excluded`, `sensitivity`, `noted`), `note` |
| `sensitivity[]` | each: what was changed (for example "exclude tickets started during main-red 10-12 14:00-20:00"), the re-run result row(s) from the engine, and whether the conclusion holds |
| `threats` | four lists: `internal` (history, maturation, selection, instrumentation, regression to the mean, novelty), `construct`, `external`, `statistical_conclusion`; each item names the evidence |
| `labels` | overall label set for the experiment, derived from the primary metric rows |
| `recommendation` | `action` (`keep`, `revert`, `extend-window`, `rerun-stratified`, `redesign`), the condition that would change it, and `next_analysis` (`at_n`, `on`, or `none`) |
| `reproduce` | the exact commands and snapshot hashes; analyst-computed checks with their script text |

### Label vocabulary and rules (validator-enforced)

Order from weakest to strongest evidence:
`not-enough-data` < `underpowered` < `inconclusive` < `no-effect-detected` <
`significant`. Modifier: `confounded`. Direction is a separate field.

- `label` must equal `engine_label` or be weaker; a weaker label needs
  `label_reason`.
- `confounded` is required on a metric when any ledger row has
  `severity: high`, lists that metric in `affects[]`, and has
  `handling: noted`. A `sensitivity` handling must point at a `sensitivity[]`
  entry.
- Every event id from the frozen events snapshot (EXP-X6-2) must appear in
  `confounders[]` (possibly `severity: none`). Missing ids reject the report.
- `analysis_type: confirmatory` requires every primary metric n to be at least
  `planned_n_per_cohort`; else the server rewrites it to `interim` and says so.
- `stats_snapshot_hash` must equal the hash the engine returns now for the same
  inputs (re-run on submit; X4 `aiur experiments stats <id> --json`).

## Markdown template

`report_markdown.ex` renders this (also copied verbatim into the skill as
`references/report-template.md` by EXP-X6-1, with a test that they match):

```markdown
# <title> - <interim|confirmatory> report v<N>

<generated_at> · analyst <agent>/<model> · stats <hash8> · events <hash8>
Labels: <label chip with "n=…/…, effect …, 95% CI […, …]"> …

## Summary
<3-6 sentences with numbers>

## Pre-registration
Hypothesis · primary · secondary · guardrails · alpha · MDE · planned n ·
registered <date> (<on time | POST-HOC>) · amendments · deviations

## Design and sample
<kind, windows, cohorts, unit, strata>
| cohort | stratum | n | excluded (reasons) |
Balance: <table of mix and standardized differences>; SRM p=<…>

## Results
| metric | role | n A / B | median A / B (IQR) | effect [95% CI] | p (adj.) | power @ MDE | n needed | label |

## Confounders reviewed
| when | kind | event | affects | bias | severity | handling |

## Sensitivity analyses
<one paragraph and result row per check>

## Threats to validity
Internal · Construct · External · Statistical conclusion

## Recommendation
<action> - <why, with numbers>. Changes if <condition>. Next analysis: <…>.

## Reproduce
<commands, hashes, analyst-computed scripts>
```

## Tests that fail without the change

- `src/test/aiur/experiments/report_contract_test.exs`:
  - accepts the golden fixture `src/test/fixtures/experiments/report.valid.json`;
  - rejects an upgraded label (`engine_label: inconclusive`, `label: significant`);
  - rejects a ledger that omits an event id from the snapshot;
  - rejects a `high`/`noted` confounder without `confounded` on the metric;
  - rejects a summary sentence "The feature is significant." (label word, no number);
  - rewrites `confirmatory` to `interim` below planned n.
- `preregistration` test: author `post_hoc: false` after `first_results_read_at`
  is stored as `post_hoc: true`; second call becomes an amendment and needs `reason`.
- `report_markdown_test.exs`: golden Markdown for the golden JSON.
- CLI test: `report submit` exit 1 with the validator message on stderr; exit 0
  prints `report v<N> stored`.

## Docs that ship

- `website/docs-app/reference/cli.md`: the two verbs (the CLI reference check,
  `website/docs-app/scripts/check-cli-reference.sh`, fails otherwise).
- `website/docs-app/concepts/experiments.md` (page created by X2): a
  "Reports and labels" section with the label ladder and the rules above.

## Risks

- X4 output shape is not final. Mitigation: the validator reads the engine row
  through one adapter function; a shape change edits only it.
- The "no bare verdict" check is a heuristic. Keep it narrow (label words only)
  to avoid rejecting good prose.

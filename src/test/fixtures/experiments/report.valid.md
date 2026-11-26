# Latency experiment - confirmatory report v1

2026-10-15T18:00:00Z · analyst codex/fixture · stats stats-fi · events events-f
Labels: inconclusive (n=after=40 / before=40, effect -2, 95% CI [-5,1])

## Summary
Both cohorts contain 40 tickets. The median difference is -2 ms with CI [-5, 1]. The result is inconclusive at p=0.2.

## Pre-registration
Registered 2026-10-09T18:00:00Z (on time)

alpha: 0.05
amendments: []
baseline_snapshot_hash: baseline-fixture
exclusions: []
experiment_id: report-example
fdr_q: 0.1
guardrail_metrics: []
hypothesis: Latency decreases by 20 percent.
mde: {"metric":"delivery/start","relative":-0.2}
planned_n_per_cohort: 40
post_hoc: false
power_target: 0.8
primary_metrics: [{"expected":"decrease","id":"delivery/start"}]
projected_ready_at: 2026-10-23
registered_at: 2026-10-09T18:00:00Z
registered_by: {"agent":"codex","model":"fixture","role":"analyst","ticket":3801}
schema_version: preregistration.v1
secondary_correction: benjamini-hochberg
secondary_metrics: []
stopping_rule: One confirmatory analysis at planned n.
stratify_by: ["complexity"]

Deviations: []

## Design and sample
cohorts: []
exclusions: {}
inclusions: {"after":40,"before":40}
kind: line
strata: ["complexity"]
unit_of_analysis: ticket
windows: {"after":{"end":"2026-10-15","start":"2026-10-09"},"before":{"end":"2026-10-08","start":"2026-10-01"}}

| cohort | stratum | n | excluded |
| --- | --- | --- | --- |
| before | pooled | 40 | {} |
| after | pooled | 40 | {} |

Balance: No material imbalance; standardized complexity difference 0.01.; SRM p=unavailable

## Results
| metric | role | n A / B | median A / B (IQR) | effect [95% CI] | p (adj.) | power @ MDE | MDE at n | n needed | label |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| delivery/start | primary | after=40 / before=40 | after=10 / before=12 (after=[7,13] / before=[8,16]) | median_difference -2 [[-5,1]] | 0.2 (0.2) | 0.65 | 0.3 | 60 | inconclusive |

delivery/start: direction: none
engine_label: inconclusive
family: holm-primary
label_reason: 
unit: ms

## Confounders reviewed
| when | kind | event | affects | bias | severity | handling |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-10-10T00:00:00Z | capacity | cap-1: Cap changed (capacity:1; capacity) | ["delivery/start"] | unknown | low | noted: Cap 8 to 6; no evidence of saturation.  |

## Sensitivity analyses
No sensitivity analyses.

## Threats to validity
construct: ["Latency excludes review time."]
external: ["One repository, 80 tickets."]
internal: ["Capacity change: cap-1."]
statistical_conclusion: ["Power 0.65 below target 0.8."]

## Recommendation
extend-window - Need 60 tickets per cohort. Changes if CI excludes zero. Next analysis: {"kind":"at_n","value":60}.

## Reproduce
analyst_computed: []
commands: ["aiur experiments stats report-example --json"]
snapshot_hashes: {"events":"events-fixture","stats":"stats-fixture"}

analysis_type: confirmatory
analyst: {"agent":"codex","model":"fixture","role":"analyst","ticket":3801}
events_snapshot_hash: events-fixture
experiment_id: report-example
generated_at: 2026-10-15T18:00:00Z
preregistration_hash: 9eb7c03545f17a417d303f7c16526fbae45e2c97645b459686770463b85ec925
report_version: 1
stats_snapshot_hash: stats-fixture
title: Latency experiment

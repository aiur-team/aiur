---
title: EXP-X7-1 Write the optimistic-start experiment spec into the experiment store - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
origin: docs/research/experiments/x7/brainstorm.md
execution: code
epic: aiur-team/aiur#3774
---

# EXP-X7-1 Write the optimistic-start experiment spec into the experiment store - Plan

## Summary

- **What.** Once the X2 store exists, register experiment `optimistic-start` with:
  - the pre-registered metrics, directions, strata, minimum samples, guardrails and stop rules from the brainstorm
  - an A/B cohort design (two Build Order queues, `start_on: pr_opened` vs `pr_merged`)
  - a before/after line at the #3755 epic close
- **Baseline.** Import the frozen 2026-10-09 baseline as the experiment's baseline snapshot.
- **Arm setup.** Document the procedure that splits the next Build Order into the two arms.

## Problem Frame

- The experiment must be pre-registered before treatment data exists. Otherwise metric choice and stop rules can be fitted to the result.
- The X2 store is the single home for specs. The page (X5) and the analyst (X6) read the spec from there.

## Requirements

Origin brainstorm R2-R11 and KD1-KD5.

## Key Technical Decisions

- **KTD1. The spec is data plus one repo fixture.** The canonical spec is stored through the X2 interface (assumed: `aiur experiments create --spec <file>`, or the store API). The same spec is checked in as a fixture so it is reviewed in a PR. The fixture path is assumed to be X2's spec directory, for example `.aiur/experiments/optimistic-start.json` in the repo or the repo state node.
- **KTD2. The baseline is imported, not recomputed.** `baseline_ref` names `docs/research/experiments/x7/baseline-2026-10-09/baseline.json` with its sha256. X2's freeze command copies it into the store as an `external` snapshot. Reason: telemetry for part of the window is gone, so a recompute would be different.
- **KTD3. Metric ids come from X2's built-in delivery-speed pack.** Chain lead time and optimistic headroom might not be in the pack. If they are missing, the spec declares them as derived metrics in the consumer extension of the pack:
  - `chain_lead_time = dependent.pr_merged - max(blocker.pr_opened)`
  - `optimistic_headroom = max(blocker.pr_merged) - max(blocker.pr_opened)`
  - They are not hard-coded in the engine (generic requirement).
- **KTD4. Cohorts are queue selectors.** Treatment = tickets whose `queue_id` is in the pr_opened arm. Control = tickets whose `queue_id` is in the pr_merged arm. The arms are recorded in the spec with the coin-flip seed and the component list. Requires the X1 `queue_id` and `start_trigger` attributes.
- **KTD5. Stop rules are guardrail metadata.** The analyst checks them on every report refresh and writes a `stop_recommended` note. The spec never changes the trigger on its own; the Executor acts.

## Directional spec shape

This is guidance on the shape, not the X2 schema.

```
id: optimistic-start
hypothesis: pr_opened start cuts chain lead time with no rise in discard/rework/main-red
kind: cohorts            # plus a line marker at #3755 close
cohorts: treatment=queue_id in {A..}  control=queue_id in {B..}
metrics:
  decision:  chain_lead_time            expect: decrease
  primary:   blocker_merge_to_dependent_start  expect: decrease (to <= 0)
  primary:   dependent_start_to_merge   expect: increase (cost)
  secondary: optimistic_headroom_used, start_to_pr_open, pr_open_to_merge,
             merged_per_hour, agents_vs_cap, idle_slot_hours
  guardrail: optimistic_discard_rate (stop >20% after >=10 starts),
             dependent_rework_rate (stop > baseline+20pt),
             merge_order_violations (stop at 1),
             main_red_rate (stop > baseline+15pt over 24h)
strata: complexity (min 10/arm), hub_gated vs chain_gated
min_samples: 20 chain-gated dependents per arm (target 40)
exclusions: late_linked dependents
tests: Mann-Whitney U, cluster bootstrap by component, Holm across decision+primaries
baseline_ref: docs/research/experiments/x7/baseline-2026-10-09/baseline.json (+sha256)
```

## Implementation Units

### U1. Write the spec fixture

- **Goal:** the spec above in the X2 format, validated by the X2 validator.
- **Requirements:** R2-R8, R10, R11.
- **Dependencies:** X2 spec+store and the metric-pack ticket. X1 cohort attributes are needed for the queue selector.
- **Files:**
  - the spec fixture under X2's spec directory (path set by X2)
  - a validation test in X2's spec test suite, for example `src/test/aiur/experiments/spec_fixtures_test.exs`
- **Test scenarios:**
  - The fixture loads and validates.
  - Each metric id resolves to the built-in pack or to a declared derived metric.
  - Removing `expect` from a primary metric fails validation (X2 rule).
  - `min_samples` below 1 fails validation.

### U2. Import the frozen baseline

- **Goal:** the store holds the 2026-10-09 baseline as the experiment's "before" snapshot, sha256-pinned.
- **Requirements:** R1.
- **Dependencies:** U1, and the X2 freeze/import.
- **Files:** none in code. The X2 freeze command is run against `baseline-2026-10-09/`.
- **Test scenarios:**
  - The imported snapshot's sha256 matches the file.
  - The page and the CLI show n = 27 and a gap median of 0.78 h for the baseline.

### U3. Add the before/after line marker at the #3755 close

- **Goal:** the experiment carries a line at the moment the last #3755 sub-issue merges.
- **Requirements:** R9.
- **Dependencies:** U1 and the X3 tagged-epic line. Without X3, the marker is added by hand.
- **Test scenarios:**
  - With the epic closed, the line timestamp equals the last sub-issue merge.
  - With the epic open, the line is pending and the report shows "not started".

### U4. Arm setup procedure (docs)

- **Goal:** a short procedure for the Executor.
- **Requirements:** R8, R10.
- **Procedure:**
  1. Take the next Build Order's planned graph.
  2. Remove review-gate tickets.
  3. List the weakly connected components.
  4. Flip a seeded coin per component.
  5. Create two queues with `aiur queue add ... --start-on pr_opened` and `--start-on pr_merged` (#3763/#3766 CLI).
  6. Record the seed and the component lists in the spec.
- **Dependencies:** #3763, #3765 and #3766 merged. G3 merge-order gate #3772 merged before any treatment run (guardrail).
- **Files:** a section in the X6 analyst skill reference, or `docs/research/experiments/x7/arm-setup.md`.
- **Test expectation:** none (docs). Verification: a dry run on the current graph lists the components and both queue commands.

## Risks

- **Too few chain-gated dependents per Build Order.** The run continues across Build Orders until min_samples. The report says "not enough data" until then.
- **G5 changes slot priority (optimistic work ranks lower).** The treatment arm may be starved under contention. Record agents-vs-cap per arm. Read a null result together with idle slot-hours.
- **The X2 format changes.** U1 is written last, after X2 merges. This ticket is blocked on the X2 store ticket.

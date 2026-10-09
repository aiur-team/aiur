---
title: EXP-X7 Optimistic-start experiment - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
epic: aiur-team/aiur#3774
measures: aiur-team/aiur#3755
area: X7 first experiment
---

# EXP-X7 Optimistic-start experiment - Plan

## Goal Capsule

- **Objective:** Measure whether optimistic dependent start (#3755) shortens the time from a blocker's PR to its dependent's merge, without raising rework, discarded work, or main-red.
- **Two parts.**
  1. Capture the "before" data now, before #3763 merges.
  2. Pre-register the experiment spec, to be written into the X2 store once it exists.
- **Product authority:** Kevin, 2026-10-09 (requirements: `docs/research/experiments/requirements.md`). The brainstorm ran unattended. The Executor made every in-the-weeds decision below and states the reason with it.
- **Open blockers:** none. The baseline is frozen (`baseline-2026-10-09/`).

---

## Problem Frame

- **The feature.** Epic #3755 lets a dependent start when its blocker's PR is opened (`start_on: pr_opened`) instead of after the merge (`pr_merged`, the default).
- **The claim.** Agents keep moving instead of waiting for review and merge.
- **The counter-risks.**
  - Work starts on code that later changes, so it is redone or discarded.
  - Stacked PRs can break main.
- **Why the baseline is urgent.** Telemetry retention already removed most of 2026-10-06 and 10-07 from disk. Without a frozen baseline, the "before" data would be gone before anyone measured the feature.

## Baseline (done; see `baseline-2026-10-09/README.md`)

Platform program dependents started 2026-10-08 to 10-09. Each value is the median [IQR] and n.

- **Blocker merge -> dependent start:** 0.78 h [0.69-3.63], n=27.
  - Chain-gated only: 1.57 h [0.27-6.53], n=8.
- **Dependent start -> merge:** 1.00 h [0.43-2.63], n=24.
- **Latest blocker PR open -> dependent start:** 2.10 h [1.77-4.69], n=27. This is the time optimistic start targets.
- **Optimistic headroom (blocker PR open -> merge), unique blockers:** 2.03 h [1.03-3.71], n=16.
- **Chain lead time (blocker PR open -> dependent merge):** 4.68 h [2.53-6.04], n=24.
- **Guardrails:**
  - Rework: 26.5% of dependents.
  - Discarded PRs: 0.
  - Main `ci` push failure rate: 38.5% (45/117).
- **Shape of the sample.** 19 of the 27 gap rows come from one release: the #3255 review gate, which blocks 73 issues.

## Actors

- **A1 Kevin / operator:** reads the verdict and decides whether `pr_opened` becomes a recommended setting.
- **A2 Experiment analyst agent (X6):** writes and updates the spec and report. It reviews confounders.
- **A3 Executor:** sets up the two Build Order arms, and freezes snapshots at #3763 merge and at the #3755 epic close.

## Requirements

- **R1. Frozen baseline before #3763 merges.** Done: `docs/research/experiments/x7/baseline-2026-10-09/`, with a copy under `~/.aiur/repo/aiur-team/aiur/executor/experiments/optimistic-start-baseline/`.
- **R2. Primary metrics** (operator-named):
  - (a) blocker merge -> dependent start gap
  - (b) dependent start -> merge
  - Both are per dependent, stratified by complexity.
- **R3. Expected direction, pre-registered.**
  - Gap: goes **down**, to at most 0 h at the median under `pr_opened`. Dependents start before the blocker merges.
  - Dependent start -> merge: goes **up**. The dependent now waits on its blocker's review, merge and restack.
  - A rising start -> merge is the expected cost. It is not a failure.
- **R4. Decision metric: chain lead time** (latest blocker PR opened -> dependent merged). Expected **down**.
  - The two primaries move in opposite directions by design, so neither one alone can say whether the feature helped.
  - The verdict sentence is about chain lead time. The primaries explain the mechanism.
- **R5. Secondary metrics:**
  - optimistic headroom used: the share of blocker PR-open -> merge time during which the dependent was already working
  - dependent start -> PR open, and PR open -> merge
  - agents vs cap, and idle slot-hours during the run
  - merged tickets per hour
- **R6. Guardrails, with stop rules.** Each guardrail metric is followed by its stop rule.
  - Optimistic discard rate (G4 `optimistic_outcome = discarded`): stop the treatment arm if it is above 20% after 10 or more optimistic starts.
  - Redo rate (G4 `redone`): report only; no stop rule.
  - Wasted agent hours: report only; no stop rule.
  - Dependent rework rate: stop if it is above the baseline (26.5%) + 20 points.
  - Merge-order violations (a dependent merged before its blocker, G3): stop at any one.
  - Main-red rate on `ci` push runs: stop if it is above the baseline (38.5%) + 15 points over 24 h.
- **R7. Minimum samples.**
  - Overall: 20 eligible chain-gated dependents per arm.
  - Per complexity stratum: 10 per arm before that stratum is reported.
  - Below the minimum, the report says "not enough data".
  - 40 per arm is the target for 80% power at a one-third reduction in chain lead time (`power.json`).
- **R8. A/B design.** Two Build Order queues run side by side in the same period: `start_on: pr_opened` (treatment) and `pr_merged` (control). Weakly connected components of the planned graph are randomized to the arms by a recorded coin flip.
- **R9. Before/after line at the #3755 epic close.**
  - Compares the frozen baseline against the period after it under the default trigger.
  - It measures the default-path changes: merged-but-open closing (G1 R7) and the G5 ramp. It does not measure optimistic start itself, because the default stays `pr_merged`.
- **R10. Hub edges are reported separately.**
  - A review-gate ticket that releases 10 or more dependents is a stratum of its own. Its dependents start together and measure the dispatch ramp.
  - Treatment queues should not contain review-gate tickets. See Open Questions.
- **R11. Confounders recorded per window:**
  - daemon restarts
  - `max_agents` changes
  - backend/model mix (Codex vs Claude)
  - provider usage-limit pauses
  - main-red incidents
  - unrelated merged PRs that touch dispatch, the queue or CI
  - G5 tickets landing during the window

## Key Decisions

- **KD1. Dependent start = first `agent:in-progress` label.** Telemetry dispatch is a cross-check. Reason: the label is on GitHub and survives telemetry retention. It agreed with telemetry to within about 2 minutes for all 34 dependents.
- **KD2. Exclude late-linked dependents.** A dependent whose `blocked_by` link was added after it started is excluded. Reason: dispatch never waited on that link, so its gap is meaningless (7 of 34 here).
- **KD3. Randomize by graph component, not by ticket.** Reason: G1 sets the trigger per queue only (no per-edge override). Dependents in one chain share a blocker. Analysis uses a cluster bootstrap over components.
- **KD4. Mann-Whitney U per stratum, Holm-corrected across the two primaries and the decision metric.** Reason: the flow times are heavily right-skewed (mean is about 2 to 3 times the median), and the X4 brief names Mann-Whitney.
- **KD5. The A/B result is the verdict; before/after is context.** Reason: before/after mixes in every change made over days (G5, restarts, backend mix). A concurrent A/B shares those confounders across both arms.
- **KD6. The baseline holds data, not code.** The scripts sit beside it under `method/` for reproducibility. The X1/X4 engines replace them.

## Approaches Considered

1. **Concurrent A/B by component (chosen).** It controls for time-varying load. It costs one extra queue setup per Build Order.
2. **Before/after only at the #3755 close.** Cheapest. But the effect is confounded with G5, restarts and fleet mix, and the default trigger does not exercise optimistic start at all.
3. **Inversion: switch the trigger on and off for the whole fleet in alternating blocks (for example, 12 h each).** No graph split is needed. But blocks carry over: optimistic work started in one block merges in the next. The samples per block are also small.

## Scope Boundaries

- **In scope:** the baseline snapshot (done), the experiment spec content, and the arm setup procedure.
- **Out of scope:**
  - building the store (X2), the stats engine (X4), the page (X5) or the analyst skill (X6)
  - changing #3755 behaviour
- **Deferred to follow-up work:** a second snapshot at #3763 merge, and a snapshot at the #3755 close. The analyst agent takes them through the X2 freeze command.

## Interfaces Assumed From Other Areas

- **X2:**
  - An experiment spec document with id, title, hypothesis, kind (`line` or `cohorts`), and cohorts as selectors on ticket attributes (here, the Build Order queue id).
  - Each metric in the spec has a pack metric id, `primary` / `decision` / `secondary` / `guardrail` role, expected direction, and an optional stop rule.
  - The spec also holds strata (complexity, hub/chain), `min_samples`, windows, and `baseline_ref`.
  - The store accepts an external frozen baseline (a path plus a sha256).
- **X1:** cohort attributes on each ticket record: `queue_id`, `start_trigger`, complexity. The pr_opened gap is fixed.
- **X4:** stratified medians/IQR, Mann-Whitney U, cluster bootstrap CI, power/MDE, Holm correction.
- **#3755 G4:** the `optimistic_start` and `optimistic_outcome` lifecycle events (BQ-G4-3 KTD1).

## Open Questions for Kevin

- Should review-gate tickets (like #3255) keep `pr_merged` even inside a `pr_opened` Build Order? Recommended: yes. A gate's point is to hold dependents until sign-off, and the G1 trigger is per queue only. Add a per-ticket "gate" exemption to G1, or keep gates out of treatment queues.
- Is chain lead time the verdict metric, with your two primaries as mechanism metrics? Recommended: yes, because the primaries move in opposite directions by design.
- Should the A/B run on the next Build Order, split 50/50 by component? Recommended: yes. Run it until 20 chain-gated dependents per arm (target 40).

---
title: Experiments X6 - Experiment analyst agent and skill - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
epic: aiur-team/aiur#3774
area: EXP-X6
researched_commits:
  origin/main: 1c4409e43
  research/refactor-findings: 6523d0f74
---

# Experiments X6 - Experiment analyst agent and skill - Plan

## Goal Capsule

- **Objective.** Give Aiur an *Experiment analyst*: an agent role with its own
  skill that writes each experiment's pre-registration and its report. The
  report is data-scientist grade. It names every change in the experiment
  window that could explain the result. The X5 page shows it.
- **Product authority.** The operator brainstorm of 2026-10-09
  (`docs/research/experiments/requirements.md`, committed by area X2). Its
  decisions are carried forward below as `session-settled`.
- **Open blockers.** One operator question (daemon-filed tickets and dispatch
  trust, see Open questions). It gates EXP-X6-5 only.

## Product Contract

### Problem

An experiment spec and a stats engine give numbers. Numbers alone mislead when
something else changed in the window: an unrelated PR made CI slower, `main`
was red for six hours, the fleet cap went from 8 to 4, or the daemon was down
overnight. Today nothing reads those events next to the metrics. Nobody states
the hypothesis before the data arrives, so a result can be explained after the
fact. The operator wants "an agent [to] drive the generation, especially for
feature pages", with "a skill specifically for this", that is "thorough and
structured in a way that data scientists would appreciate".

### Actors

- **Experiment analyst** (new role): a coding agent (Claude or Codex) that loads
  the `aiur-experiment` skill. It works one experiment and one mode per run.
- **Daemon**: requests an analyst run when an experiment reaches a trigger
  point (from X3).
- **Executor** (human or agent): requests a run on demand, or runs the analyst
  in its own session as a background agent.
- **Operator / consumer-repo user**: reads the report on the X5 page, and can
  run `aiur experiments analyze <id>`.

### Key decisions

- **KD1 - Mirror Build Orders: one skill, one durable store, one page.**
  `session-settled: operator, 2026-10-09` ("Similar to Build Orders, an
  Experiment analyst agent with its own skill drives the generation"). As
  `aiur-build` writes a pack to the repo state node and the Build Order page
  reads it, the analyst writes into the X2 experiment store and X5 reads it.
  The analyst never edits page code and never writes report files into `docs/`.
- **KD2 - Two modes: `spec` and `report`.** `spec` writes the pre-registration
  (hypothesis, primary and secondary metrics, expected direction, alpha, MDE,
  planned sample size, stopping rule) before any post-treatment outcome data
  exists. `report` analyzes the data. A run is one mode. Reason: pre-registration
  is only worth something if it is written blind to the result.
- **KD3 - Blindness is enforced, not requested.** In `spec` mode the analyst
  may read the frozen baseline (pre-period) and sample *counts*, never
  post-period outcome values. The store records the time of the first
  post-period results read. A pre-registration written after that time is
  stored and shown as **post-hoc**. Reason: a skill instruction alone cannot
  prove blindness; a timestamp can.
- **KD4 - The analyst interprets; the stats engine computes.** p-values, CIs,
  effect sizes, power, MDE, samples-needed and multiple-comparison adjustments
  come from the X4 engine output, pinned by its snapshot hash. The analyst does
  not recompute them by hand. If the engine lacks a statistic, the analyst may
  add one only as a marked "analyst-computed" sensitivity check with its script
  attached. Reason: reproducible numbers, and a cheap model cannot get
  arithmetic wrong.
- **KD5 - Labels are monotone.** X4 computes the mechanical label per metric
  (`not-enough-data`, `underpowered`, `inconclusive`, `no-effect-detected`,
  `significant`). The analyst adds `confounded` and may *downgrade* a label
  with a stated reason. It may never upgrade one (for example `inconclusive` to
  `significant`). The submit validator enforces this.
- **KD6 - Confounder review is a ledger, not prose.** Every event in the window
  is listed with its kind, time, the metrics it could move, the plausible
  direction of bias, a severity (`none`, `low`, `high`) and the handling
  (excluded tickets, sensitivity analysis, or noted only). Event kinds: merged
  PRs (feature, bug fix, unrelated), releases and version changes, config
  changes (config hash), incidents (alerts, incident-labelled issues), daemon
  outages and restarts, base-branch red periods, fleet-capacity changes (cap,
  effective cap, global pauses). Aiur collects the events; the analyst
  classifies them. A `high` confounder that is not handled makes the metric
  `confounded`.
- **KD7 - No bare verdict word.** `session-settled: operator, 2026-10-09`
  ("no bare verdict word on the page"). Every label is shown with n per
  cohort, the effect and its CI. The summary states numbers, not adjectives.
- **KD8 - Default run path is a fleet ticket; the Executor path is the same
  skill.** Daemon triggers and `aiur experiments analyze <id>` file one
  *analysis ticket* that the fleet dispatches like any other ticket. The ticket
  produces no PR: it ends when the report is submitted, and moves to `done`
  without human review (the turn workflow already allows this when the issue
  says so, `.claude/skills/aiur-agent/turn-workflow.md:83`). The Executor can
  instead run the skill in a background agent; it parks the ticket first.
  Reason: the daemon has no Executor in a headless or consumer-repo run, the
  fleet already has load governance and model routing, and both paths write
  through the same CLI so the result is identical.
- **KD9 - The skill is generic.** `session-settled: operator, 2026-10-09`
  ("The definition of a feature needs to remain generic"). The skill reads
  metric names, units and direction from the experiment spec and its metric
  pack (X2). It has no Aiur-specific metric logic. The "delivery speed" pack
  is one input. The skill ships to every ticket workspace (like `aiur-agent`),
  so a consumer repo's fleet has it with no setup.
- **KD10 - One confirmatory look.** Interim reports (after the minimum sample
  guard) are labelled *interim, descriptive*. The confirmatory analysis runs
  once, at the planned sample size from the pre-registration. Reason: repeated
  looks inflate false positives; one planned look is the simplest valid rule.
- **KD11 - Daemon triggers fire once per point.** Per experiment: `spec` at
  creation (feature experiments only; release experiments use the built-in
  "no regression" template with no agent), `report` when the minimum sample
  guard is met (interim), and `report` when the planned n is met
  (confirmatory). One open analysis ticket per experiment at a time.

### Requirements

- R1. A skill `aiur-experiment` covers both modes, the confounder review, the
  statistics interpretation rules, the label rules, and the report template.
- R2. `aiur experiments analyze <id> [--mode spec|report] [--local]` requests a
  run. Without `--local` it files (or reuses) the analysis ticket. With
  `--local` it prints the analyst brief for the caller's own agent and files
  nothing.
- R3. `aiur experiments events <id> --json` returns the window-event ledger
  input, from Aiur and GitHub sources, and freezes it with the report.
- R4. `aiur experiments preregister <id> --file` and
  `aiur experiments report submit <id> --file` validate and store. The
  validator rejects a report with missing sections, unknown labels, an upgraded
  label, a stats snapshot hash that does not match, or a confounder ledger that
  omits a collected event.
- R5. The daemon requests runs at the KD11 points, from X3 events.
- R6. The report renders on the X5 page with no page-specific logic in the
  analyst (the page renders the stored report).
- R7. A consumer repo gets the skill in every workspace and can run the full
  flow on its own metric pack.

### Success criteria

- A fixture experiment with a seeded confounder (a red-`main` period and a cap
  drop inside the after-window) produces a submitted report that lists both
  events, marks the affected metrics `confounded` or handles them with a
  sensitivity analysis, and renders on the page.
- A pre-registration submitted after the first results read is shown as
  post-hoc.
- A report that changes an engine label from `inconclusive` to `significant`
  is rejected by the validator.

### Scope boundaries

- In scope: the skill, the report contract and template, the run flow and
  triggers, the window-event collector, submission and validation.
- Out of scope (other areas): event capture and cohort attributes (X1); spec,
  metric packs, baseline freeze and the store (X2); creating experiments
  automatically (X3); computing statistics (X4); page and charts (X5); the
  first live experiment (X7).
- Not built: causal-inference models (difference-in-differences, synthetic
  control), sequential alpha spending, Bayesian analysis. Reason: one planned
  look plus confounder handling is enough for the sample sizes Aiur sees (tens
  to low hundreds of tickets per window). They can be added later as engine
  methods without changing the skill contract.

### Interfaces assumed from other areas

| From | Assumed interface | Used by |
|---|---|---|
| X1 | Per-ticket records carry `aiur_version`, `backend`, `model`, `config_hash`, epic and consumer tags; a config-hash or version change is visible as a time series | EXP-X6-2 |
| X2 | Store at `~/.aiur/repo/<owner>/<repo>/experiments/<id>/`; facade with `get/1`, `put_preregistration/2`, `put_report/2`, `record_results_read/1`; spec fields `kind` (`line` or `cohorts`), `windows`, `metrics` (pack + id, unit, `better: lower or higher`), `min_samples`, optional `confounder_sources`; `aiur experiments list/show` | EXP-X6-2, -3, -4 |
| X3 | Daemon events `experiment.created`, `experiment.sample_guard_met`, `experiment.planned_n_met` with `experiment_id` and `kind` (`release`, `feature`, `manual`) | EXP-X6-4 |
| X4 | `aiur experiments stats <id> --json` returning per-metric descriptives, effect, CI, p, adjusted p and family, power, MDE, samples-needed, the mechanical label, balance/SRM checks, and a `snapshot_hash` over its inputs | EXP-X6-1, -3 |
| X5 | Page renders the stored `report.v1` (sections in order, label chips with numbers, confounder ledger table) | EXP-X6-6 |

If an area lands a different shape, the X6 plans change at the named touch
point only; the skill reads everything through these CLI verbs.

### Open questions for Kevin

1. Daemon-filed analysis tickets need dispatch trust. Today a ticket is
   dispatchable only when an allow-listed user applied its `agent:*` label
   (`src/lib/aiur/github/dispatch_authorization.ex:497`). Options: (a) a narrow
   provenance rule - the daemon's own login created the issue *and* its body
   nonce matches a pending analysis request in the local store; (b) the daemon
   files with `human:todo` and the Executor promotes it. **Recommendation: (a)**,
   scoped to the analysis marker only, because it keeps triggers automatic in
   headless and consumer runs and cannot be forged without local store access.
2. Should a report need Executor sign-off before the page shows its
   recommendation? **Recommendation: no.** The report is reproducible from
   pinned inputs and is re-run on demand; the page shows analyst, model and
   time with it.

## Ticket map

| Ticket | Plan | Complexity | In-area blocked by |
|---|---|---|---|
| EXP-X6-1 Write the analyst skill | [plan-analyst-skill.md](plan-analyst-skill.md) | 2 | - (builds on the contracts in -2, -3, -4 plans) |
| EXP-X6-2 Collect the window-event ledger | [plan-window-events.md](plan-window-events.md) | 3 | - |
| EXP-X6-3 Pre-registration and report contract | [plan-report-contract.md](plan-report-contract.md) | 2 | - |
| EXP-X6-4 Trigger and run the analyst | [plan-run-flow.md](plan-run-flow.md) | 3 | - |
| EXP-X6-5 Dispatch trust for analysis tickets | [plan-dispatch-trust.md](plan-dispatch-trust.md) | 2 | EXP-X6-4 |
| EXP-X6-6 End-to-end proof (capstone) | [plan-e2e-proof.md](plan-e2e-proof.md) | 2 | EXP-X6-1..5 |

Wave 1 runs -1..-4 in parallel against the reviewed contracts in the plans
(the skill text names CLI verbs, not code). Cross-area edges for the Executor:
-2 after X1 and X2; -3 after X2 and X4; -4 after X2 and X3; -6 after X5.

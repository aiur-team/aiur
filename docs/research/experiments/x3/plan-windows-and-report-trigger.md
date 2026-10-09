---
title: EXP-X3-4 After-window manager, sample guard and analyst wake - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x3/brainstorm.md
epic: aiur-team/aiur#3774
---

# EXP-X3-4 After-window manager, sample guard and analyst wake - Plan

## Summary

A single `WindowManager` owns every line experiment in `collecting` state,
whether it was created automatically or by hand:

- it extends the after window in steps while the sample guard is unmet;
- it truncates the window on the next line of the same source or on a
  rollback;
- it moves the experiment to `report_due` exactly once.

A `Notifier` publishes the `system.experiment.<id>.preregister`, `.report_due`
and `.cancelled` events from a durable latch. The Executor wake bindings
include those events. Product Contract unchanged.

## Problem frame

Without a trigger, someone must remember to come back after 14 days. Report
timing also matters for rigor:
- too early, and the report is underpowered;
- never, and the baseline was frozen for nothing.

Two existing patterns cover the rest:
- **Durability:** `Aiur.BuildProgress` persists a latch before it publishes,
  so after a crash it may miss a notification but never repeats one
  (`src/lib/aiur/build_progress.ex:140-160`).
- **Waking the Executor:** `Aiur.ExecutorBindings` allowlists event topics for
  the wake inbox (`src/lib/aiur/executor_bindings.ex`).

## Requirements

R6, R7, AE5 of origin.

## Key technical decisions

- **Evaluation cadence.** The manager evaluates every 60 minutes, and on
  `ticket.*.pr.merged` (debounced 10 minutes). Each evaluation calls X4's
  `sample_status/1` for each experiment in `collecting`. Its cost is a read
  of the run summaries; X4 owns caching it.
- **Transitions:**
  - The guard is met and the after window has run at least `after_days`. The
    experiment moves to `report_due` with reason `guard_met`. The minimum
    duration stops a burst day from deciding the result.
  - The window end is reached and the guard is unmet. The after window
    extends by `after_step_days`, but not past `after_max_days`.
  - The window end is reached at `after_max_days`. The experiment moves to
    `report_due` with reason `insufficient_data` (AE5).
  - The window is truncated by a new line of the same source, or by a
    rollback. If the guard is met at that moment, the reason is `guard_met`;
    otherwise it is `truncated`.
- **X4 not available.** If X4's `sample_status` is not registered yet, the
  guard is treated as unmet. Experiments then end at `after_max_days` with
  reason `insufficient_data`. They are never stuck.
- **Notifier.** Latches live in
  `<state node>/experiments/auto-latches.json`, keyed `{experiment_id,
  event}`. The latch is persisted first, then the event is published on
  `Aiur.Events.Exchange`, using the event shape that `Alerts.emit_system`
  produces (`src/lib/aiur/alerts.ex:104,149`). The payload is
  identifier-only (`experiment_id`, `reason`, `line_source`) and holds no
  report data.

  Using Exchange directly keeps `experiments` off `executor-attention` as a
  required dependency (MP-R1 R-down / R-optional). Operator-visible alerts are
  X5's page, not an alert sound.
- **Bindings.** Add `{"system.experiment.*.preregister", "experiments:auto"}`,
  `{"system.experiment.*.report_due", "experiments:auto"}` and
  `{"system.experiment.*.cancelled", "experiments:auto"}` to
  `ExecutorBindings` `@defaults`.
- **Manual experiments.** A hand-written spec (X2) whose kind is `line` and
  whose status is `collecting` is managed in the same way. The same guard
  applies whoever created the experiment.
- **`truncate/3` in the facade.** `Aiur.Experiments.Auto.truncate(id, at,
  reason)` is the facade entry EXP-X3-2 calls on a rollback, and other
  sources call on a newer line.

## Implementation units

### U1. WindowManager

**Files:** `src/lib/aiur/experiments/auto/window_manager.ex` (GenServer),
`src/lib/aiur/experiments/auto/window_rules.ex` (a pure function:
`evaluate(experiment, sample_status, config, now)` returns an action), tests.

**Execution note:** Write the `window_rules` tests first. They are a table of
(state, sample status, now) giving the expected action.

**Test scenarios:**
- Guard met on day 9: no transition. On day 14: `report_due` with reason
  `guard_met`.
- Guard unmet on day 14: the after window end moves to day 21.
- Guard unmet on day 42: `report_due` with reason `insufficient_data`
  (covers AE5).
- `after_days: 14`, `after_step_days: 7`, `after_max_days: 30`: extensions go
  to 21, then 28, then 30 (clamped).
- `truncate` on day 8 with the guard unmet: `report_due` with reason
  `truncated`, and the after end is set to day 8.
- X4 is missing: the guard is unmet, and the extensions end at
  `insufficient_data`.
- An experiment already `report_due` gets no further actions.
- A `pr.merged` burst of 20 events within 10 minutes triggers one evaluation.

### U2. Notifier and latch

**Files:** `src/lib/aiur/experiments/auto/notifier.ex`, tests.

**Test scenarios:**
- The first `report_due` persists the latch, then publishes one event with an
  identifier-only payload.
- The same transition again publishes nothing.
- After a restart, the latch reloads and nothing is published again.
- If the latch write fails, nothing is published, an error is logged, and
  the next evaluation retries. A missed notification is preferred over a
  duplicate.
- A corrupt latch file disables publishing and reports `degraded` in
  `status/0`. It does not wipe the file and re-notify everything.

### U3. Executor wake bindings

**Files:** `src/lib/aiur/executor_bindings.ex`,
`src/test/aiur/executor_bindings_test.exs` (or the existing listener test).

**Test scenarios:**
- `allowlisted?("system.experiment.*.report_due")` is true.
- An event published on `system.experiment.exp-1.report_due` reaches
  `ExecutorWakeInbox` as one wake record. This is an integration test with
  the listener and the inbox, as in the existing `ticket.*.pr.merged` tests.
- `system.experiment.exp-1.internal` is not allowlisted.

## Verification contract

- The unit and integration tests pass.
- On the runtime daemon, a hand-made line experiment with a 1-day after
  window and `min_samples: 1` reaches `report_due`. Exactly one wake appears in
  the Executor wake inbox (`aiur executor wait`, or `wakes.ndjson`).

## Documentation

- Experiments concept page, section "When the report is written": the minimum
  window, extension, the maximum, truncation, and the reasons.
- `.claude/skills/aiur-run/references/executor.md`: a short "experiment
  wakes" entry: on `preregister` or `report_due`, start the analyst flow (X6).
  On `cancelled`, do nothing.

## Risks

- **A large X4 evaluation every hour.** Mitigation: evaluate only experiments
  in `collecting`, and let X4 cache by run-summary generation.
- **Wake noise.** At most three events per experiment over its whole life.

## Dependencies

EXP-X3-1 (in area). Cross-area: X4 `sample_status/1`, and X6 consuming the
events. Both are soft, with the defined fallback.

## Definition of done

U1 to U3 are merged with tests. The runtime check produces exactly one wake.
Docs are shipped.

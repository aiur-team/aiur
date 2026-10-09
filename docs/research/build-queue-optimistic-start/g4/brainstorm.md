---
title: G4 failure and waste of optimistic dependent start - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
epic: aiur-team/aiur#3755
area: G4
code_baseline: origin/main 0e5b8d0de
---

# G4 failure and waste of optimistic dependent start - Plan

## Goal Capsule

- **Objective:** When a dependent starts before its blocker merges (G1 trigger
  `pr_opened`, `pr_ci_green` or `pr_approved`), Aiur must (a) do the right thing
  when the blocker fails, and (b) count the optimistic work that was redone or
  thrown away, so the Executor can tune the start trigger with evidence.
- **Product authority:** Kevin (operator intent in the epic brief). This
  brainstorm ran unattended; each decision below records its reason.
- **Open blockers:** none for planning. Three operator questions are listed at
  the end; each has a recommended default that the plans use.

## Problem frame

Optimistic start trades a risk for speed. Today nothing names the risk:

- `Readiness.classify/2` already detects blocker failure (`:agent_error`,
  `:pr_closed_unmerged`, `not_planned`, `duplicate`) at
  `src/lib/aiur/build_queue/readiness.ex:58-74`, and the planner opens
  `prerequisite_failed` keyed on the **blocker** (`planner.ex:135-141`). That
  attention tells the Executor to "re-plan or remove the dependents". It does
  not know a dependent already ran, and it does nothing to the running agent.
- `dependency_changed_after_start` fires for any claimed, promoted dependent
  whose verdict is not `:ready` (`planner.ex:129-131`). Under optimistic start
  every dependent is claimed while its blocker is still open, so with today's
  verdict the attention would fire on every optimistic start. It is noise in
  the success case and too vague in the failure case.
- Dispatch's `blocked_by` gate only applies to `todo` issues
  (`dispatch_policy.ex:987-995`). A running dependent is never stopped by a
  blocker change.
- The live run has no adopted queue (waves are promoted by hand with native
  `blocked_by`). A policy that lives only in the queue planner would not run.
- Measurement: run telemetry lifecycle events
  (`run_telemetry/lifecycle.ex:15-19`) feed both the Python reducer
  (`analytics/lib/analytics/reduce.py`) and the Build Order page's Analytics
  pane (`aiur_web/operator_control_center/analytics/presenter.ex:696-723`,
  KPI tiles in `components/operator_control_center/build_order_analytics.ex:141`).
  No event records that a start was optimistic, so no report can tell the
  trigger's cost from its benefit.

## Product Contract

### Actors

- **Executor** (primary): reads attentions and reports, decides what to do with
  parked optimistic work, tunes the start trigger.
- **Dependent worker agent**: started optimistically; integrates blocker pushes
  (G2); is paused when its blocker fails.
- **Operator (Kevin)**: sets the default trigger; reads the Build Order page.

### Vocabulary

- **Optimistic start**: a dispatch where at least one `blocked_by` blocker was
  open (not closed `completed`) and the start trigger let it through.
- **Optimistic blocker**: a blocker that was open at the dependent's start.
- **Blocker failure (terminal)**: the blocker cannot deliver the code the
  dependent built on. Signals: blocker PR closed unmerged and no replacement PR
  within the grace; blocker issue closed `not_planned` or `duplicate`; blocker
  removed from the Build Order or queue.
- **Blocker trouble (non-terminal)**: the blocker may still deliver. Signals:
  blocker in `agent:error`, paused, parked, or reset to `todo`.
- **Blocker churn**: the blocker's branch moved in a way that forced the
  dependent to redo work: a non-fast-forward push, or an integration that
  conflicted.
- **Head start**: for a dependent whose blocker merged, the time between the
  dependent's start and the blocker's merge. This is the wait the `pr_merged`
  trigger would have imposed, before slot contention.

### Requirements

**Failure policy (ticket BQ-G4-2)**

- R1. Aiur records every optimistic start durably: dependent, each optimistic
  blocker, the blocker's PR number and head SHA at start, the trigger in force,
  and the start time. The record survives a daemon restart. (BQ-G4-1)
- R2. On terminal blocker failure, Aiur pauses a running dependent through the
  existing pause path, keeps its workspace, branch and PR, marks the PR draft if
  it is not already, adds `agent:parked`, and posts one issue comment that names
  the blocker and the cause. It does not close, delete or rebase anything.
- R3. A dependent that already finished its turn (PR open, waiting for review or
  for the blocker) gets the same treatment except the pause, which is a no-op.
- R4. A dependent that is promoted but not yet claimed is not G4's concern: the
  G1 gate stops treating the blocker as started and the existing queue
  withdrawal applies.
- R5. On non-terminal blocker trouble, the dependent keeps running. Aiur opens
  the dependent-scoped attention with an `informational` severity only after the
  trouble persists past the grace, so a blocker retry does not page anyone.
- R6. A blocker PR closed and reopened, or replaced by a new PR from the same
  issue within the grace (default 600 s, `build_queue.optimistic_failure_grace_seconds`),
  is churn, not failure. The record updates to the new PR.
- R7. Blocker churn never pauses the dependent; integrating the blocker is the
  dependent's job (G2). Churn is counted (R10). When one dependent absorbs
  `optimistic_churn_attention_threshold` (default 3) conflicting integrations,
  Aiur opens one attention so the Executor can switch that queue to a later
  trigger.
- R8. The Executor learns about a failure through one dependent-scoped queue
  attention, `ticket.<dependent>.queue.attention.optimistic_blocker_failed`,
  which the existing `ticket.*.queue.attention.#` binding already routes to the
  wake inbox. Its message names the blocker, the cause, what Aiur did (paused /
  parked, branch kept), and the three choices: wait for a replacement blocker,
  re-base the dependent on the default branch and resume it, or close it.
  The blocker-scoped `prerequisite_failed` stays as it is and gains the list of
  dependents that had already started.
- R9. `dependency_changed_after_start` stays for its original meaning (a
  dependent whose readiness regressed after a non-optimistic start). For an
  optimistic dependent it is suppressed while the trigger condition holds, and
  replaced by `optimistic_blocker_failed` when it does not. One cause per
  dependent at a time.
- R9a. The policy runs whether or not a queue is adopted. It keys on the
  dependent's native `blocked_by` plus the optimistic-start record, not on queue
  membership.

**Measurement (ticket BQ-G4-3)**

- R10. Per optimistic dependent, Aiur counts: blocker pushes absorbed, clean
  integrations, conflicting integrations, non-fast-forward blocker pushes,
  parks caused by blocker failure, resumes after such a park, and the final
  outcome (`merged`, `merged_after_redo`, `discarded`, `open`).
- R11. Per optimistic dependent that merged, Aiur computes the head start
  (blocker merge time minus dependent start time, floored at zero). Per
  discarded dependent, Aiur records the active agent time spent before the
  discard as waste.
- R12. Each count is a run-telemetry lifecycle event, so it shows up in
  `analytics/run-summary`, `analytics/build-report`, and the Build Order page
  without a new storage path. The durable record from R1 holds the running
  totals for live reads and restart safety.
- R13. Reports group by start trigger, so the Executor can compare
  `pr_opened` against `pr_approved` from real runs.
- R14. The Build Order page's Analytics pane adds one KPI tile: optimistic
  starts, with redone / discarded counts and total head start as the sub-line.
  The member gantt marks an optimistic park.

### Success criteria

- A blocker PR closed unmerged with no replacement pauses and parks every
  running optimistic dependent within one reconcile or event cycle, keeps the
  branch, and wakes the Executor exactly once per dependent.
- A blocker in `agent:error` that the Executor retries within the grace causes
  no pause and no page.
- No `dependency_changed_after_start` fires for an optimistic dependent whose
  blocker is healthy.
- `analytics/build-report <slug>` prints optimistic starts, redone, discarded,
  head start and waste, grouped by trigger, and the Build Order page shows the
  same numbers for the current session.

### Scope boundaries

- In: failure detection and response for dependents that already started;
  counters, reports, page tile.
- Out: choosing the trigger (G1); subscriptions, integration mechanics and the
  skill section (G2); restack after squash merge and the merge-order gate (G3);
  slot priority and optimistic share cap (G5).
- Out: automatic discard (closing PRs, deleting branches). See Q1.
- Out: automatic trigger tightening from measured waste. See Q3.

## Approaches considered

1. **Queue-planner only.** Extend `prerequisite_failed` and let the planner
   decide. Cheap, but the live run has no adopted queue and the planner cannot
   pause an agent. Rejected.
2. **Agent-driven.** Subscribe the dependent to the blocker's failure events and
   let the skill decide whether to stop. Reuses G2's wiring, but an agent mid
   turn may never read the event, and the Executor learns nothing durable.
   Kept as a secondary signal only.
3. **Orchestrator guard with a durable optimistic ledger (chosen).** A small
   orchestrator component owns the ledger, listens to `ticket.*.pr.closed_unmerged`
   (already published by `BuildQueue.PRObserver`, `pr_observer.ex:302-303`),
   `pr.opened`, `pr.merged`, `branch.push`, and the issue state it already
   polls, applies the policy, and emits lifecycle telemetry. The queue
   planner reads the ledger only to suppress or replace its own attentions.
   Works with and without a queue; one place to count.

Challenger considered: auto-discard plus re-dispatch on the default branch.
Higher upside when blockers fail often, but it destroys work the Executor may
want (a replacement blocker often lands the same API). Not chosen for v1.

## Key decisions

- **D1. Park, do not discard.** Reason: discarding is the only irreversible
  step, the Executor can discard in one command, and a replacement blocker
  often makes the parked work usable. Kevin prefers the Executor to decide.
- **D2. Terminal versus non-terminal split.** Reason: `agent:error` on the
  blocker is usually a retry away; pausing the dependent would waste the slot's
  progress and add a resume cycle for nothing.
- **D3. Grace before failure (600 s, reuse `merged_open_grace_seconds` range).**
  Reason: agents close and reopen PRs from the same branch to clear stuck review
  gates; that must not park dependents.
- **D4. One new ticket-scoped cause, `optimistic_blocker_failed`.** Reason:
  `prerequisite_failed` is blocker-scoped and `dependency_changed_after_start`
  says "decide whether it pauses"; neither says "Aiur paused it, here is what
  is kept". Reusing the queue-attention topic family gets Executor routing and
  durable latches for free.
- **D5. Counters are lifecycle telemetry, not a new ledger file for reports.**
  Reason: the reducer, build-report and the Build Order pane already read
  lifecycle telemetry; a second store would drift. The optimistic record (R1)
  holds live state only.
- **D6. Head start, not "time saved".** Reason: the counterfactual under
  `pr_merged` includes slot waits Aiur cannot know; calling it saved time
  would overstate the benefit.
- **D7. Churn threshold attention at 3 conflicting integrations.** Reason: one
  conflict is normal stacking; repeated conflicts mean the trigger is too early
  for that blocker.

## Seams with other areas (assumed interfaces)

- **G1:** dispatch must tell G4 which blockers were open at start. Assumed:
  the dispatch decision for a ticket carries `optimistic_blockers :: [blocker_id]`
  and the trigger name, and the dispatcher calls
  `Aiur.Orchestrator.OptimisticLedger.record_start/2` before the runner starts.
  G1 must also make the planner's verdict trigger-aware so that
  `dependency_changed_after_start` does not fire for a healthy optimistic
  dependent (G4 adds the suppression check; G1 owns the verdict).
- **G2:** the dependent's automatic blocker subscriptions include
  `ticket.N.pr.closed_unmerged`; the skill's optimistic section tells the agent
  to emit `ticket.<self>.optimistic.integrated` with `{blocker, sha, conflict, non_ff}`
  after each blocker integration, and what to do on resume after an optimistic
  park. G4 consumes that event for R10.
- **G3:** restacks after squash merge emit the same `optimistic.integrated`
  event. The merge-order gate keeps a parked dependent from merging.
- **G5:** may later read the discard rate from the same telemetry to size the
  optimistic share cap. Not required for v1.

## Open questions for Kevin

- **Q1.** Should Aiur ever discard optimistic work on its own (close the PR,
  delete the branch)? Recommended: no; park and let the Executor decide.
- **Q2.** Should non-terminal blocker trouble (`agent:error`) also pause the
  dependent to free its slot? Recommended: no; attention after the grace only.
- **Q3.** Should Aiur tighten the start trigger by itself when the measured
  discard rate is high? Recommended: not in v1; report only, the Executor tunes.

## Tickets

- BQ-G4-1 Record optimistic starts durably (ledger + lifecycle events). Plan:
  `plan-optimistic-ledger.md`.
- BQ-G4-2 Park optimistic dependents when their blocker fails. Plan:
  `plan-blocker-failure-policy.md`. Blocked by BQ-G4-1.
- BQ-G4-3 Report redone and discarded optimistic work. Plan:
  `plan-optimistic-waste-report.md`. Blocked by BQ-G4-1.

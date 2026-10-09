---
title: BQ-G1 start trigger - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
epic: aiur-team/aiur#3755
area: G1 start trigger
---

# BQ-G1 start trigger - Plan

## Goal Capsule

- **Objective:** let the operator choose when a dependent ticket may start relative to its blocker's pull request, with one policy that both the build queue (promotion) and dispatch (the `blocked_by` gate) obey.
- **Product authority:** Kevin's intent in epic #3755 ("PR merge ... should be the default"; "the optimistic PR open"; "keep agents moving tickets as quickly as possible"). This brainstorm ran unattended; every in-the-weeds decision below is the Executor's, with its reason.
- **Open blockers:** none. Operator questions are listed at the end; each has a recommended default that the tickets already assume.

---

## Problem

Two gates decide when a dependent starts, and they disagree.

1. **Queue promotion** (`src/lib/aiur/build_queue/readiness.ex`): an edge is `:satisfied` only when the blocker issue is closed `completed`. A merged PR whose issue is still open stays `:pending`; `merged_open_grace_seconds` (default 600) only raises the `merged_issue_open` attention (`planner.ex` `merged_keys/2`).
2. **Dispatch** (`src/lib/aiur/orchestrator/dispatch_policy.ex:857`, `todo_issue_blocked_by_non_terminal?/2` at :987): a `todo` ticket is skipped with `{:skip, :dependency}` while any `blocked_by` entry has a non-terminal state. Terminal states come from `tracker.terminal_states` (default `Closed, Cancelled, Canceled, Duplicate, Done`), so `agent:done` and any closed issue (including `not_planned`) unblock dispatch, while the queue fails a `not_planned` blocker.

Neither gate can start a dependent while its blocker's PR is open, in CI, or in Executor review. That window is the gap Kevin wants to use. The gate is called from at least nine places (`dispatch_candidates.ex:23,27`, `status_report.ex:1273`, `issue_sync.ex:242,2321,2356`, `pause_resume.ex:2414`, `dispatcher.ex:1251,1298,1405`), so a trigger added to one call site and not the others would make the status board, auto-resume and dispatch disagree.

## Actors

- **A1 Executor / operator:** sets the trigger for a queue or Build Order, reads why a ticket waits.
- **A2 Build queue server:** promotes members (`agent:todo`) when readiness says `:ready`.
- **A3 Orchestrator dispatch:** starts an agent for a `todo` ticket when the gate allows.
- **A4 Areas G2-G5:** consume the fact "this start was optimistic" (subscribe, stack safety, failure policy, capacity).

## Requirements

- **R1. Five triggers, one ladder.** `issue_closed` < `pr_merged` < `pr_approved` < `pr_ci_green` < `pr_opened`, from strictest to most optimistic. A stage later in the PR life satisfies every earlier trigger (a merged PR satisfies `pr_approved`, `pr_ci_green`, `pr_opened`).
- **R2. Default is `pr_merged`.** Config `build_queue.start_trigger` defaults to `pr_merged`. It applies to every dependent that no queue overrides, including tickets gated only by native `blocked_by` links (the current live run).
- **R3. Per-queue override.** A queue (a named list or an adopted Build Order) can carry its own trigger, set at `aiur queue add ... --start-on <trigger>` and changed with `aiur queue set <queue> --start-on <trigger>`. No per-item or per-edge override.
- **R4. One policy function.** Queue readiness and the dispatch gate call the same pure function with the same evidence shape. The result names the cause (`:satisfied`, `:pending`, `{:unknown, cause}`, `{:failed, cause}`) and whether a satisfied edge is final (blocker merged or closed) or optimistic.
- **R5. Never a false ready.** Missing or stale evidence yields `:pending` (when fresher evidence says an earlier stage) or `{:unknown, cause}`; never `:satisfied`.
- **R6. Monotonic per PR.** Once a blocker's PR has reached a stage, that stage stays reached for that PR number. Later regressions (new push re-running CI, approval dismissed, ticket back to `rework`) do not re-block a dependent. A PR closed unmerged, or a different PR number, resets the ladder.
- **R7. Merged-but-open gap closed under `pr_merged`.** A merged PR satisfies the edge without waiting for the issue to close. `merged_issue_open` is raised only for dependents under `issue_closed`, where it still holds them.
- **R8. Dispatch preserves today's failure semantics.** Dispatch keeps treating a closed `not_planned`/`duplicate` blocker as no longer holding (today's behaviour); the queue keeps failing it. The shared function returns the fact; each caller passes its own `not_planned` policy.
- **R9. Optimistic starts are visible.** When dispatch starts a ticket whose blocker is satisfied but not merged, the run records which blockers were optimistic. G2-G5 read that record.
- **R10. Surfacing.** `aiur queue show`, the dispatch `[waiting=...]` / decline log line and the queue panel name the trigger and the missing stage ("#12 needs pr_ci_green; CI pending on PR #99"). Docs describe the setting and the ladder.

## Acceptance Examples

- **AE1.** Queue under `pr_opened`. Blocker #12 enters `agent:ci-wait` with ready PR #99. Within one reconcile, dependent #13 is promoted to `agent:todo` and dispatched; the run records `optimistic_blockers: ["12"]`.
- **AE2.** Default config, no queue. Blocker #12 PR merged, issue still open (reconciler has not written `done`). Dependent #13 dispatches on the next tick; no `merged_issue_open` attention.
- **AE3.** Queue under `pr_ci_green`. Blocker #12 passed CI on head A, then pushed head B (CI pending). #13 stays eligible (R6).
- **AE4.** Queue under `pr_approved`. Evidence row for #12 is older than `observation_max_age` and labels are stale. #13 reads `unknown (stale)`, is not promoted, and dispatch declines it.
- **AE5.** Queue under `pr_opened`. #12's PR is closed unmerged. Edge becomes `{:failed, :pr_closed_unmerged}`; an already-running #13 is not killed by G1 (G4 owns that policy).

## Scope Boundaries

- In scope: the setting, the evidence store, the shared policy, both gates, surfacing, docs.
- Not in G1: subscribing the dependent to blocker pushes and the agent skill text (G2); restack and merge-order gate (G3); what to do with optimistic work when the blocker fails (G4); slot priority and optimistic share caps (G5).
- Not in scope: a trigger per edge or per item; Linear tracker support beyond `issue_closed`/`pr_merged` (Linear's `ticket_pull_request/1` returns `nil`, so the optimistic triggers read `pending` there and docs say so).

## Key Decisions

- **KD1. Ladder order puts `pr_approved` before `pr_ci_green`.** Aiur's Executor reviews only in `agent:human-review`, which the daemon gates on CI passing the current head, so approval comes after green. Ordering by real lifecycle makes "a later stage satisfies earlier triggers" true.
- **KD2. Evidence comes from facts the daemon already keeps, not a new CI poll.** Rejected: a dedicated per-minute GraphQL poll of every blocker PR (cost and a second CI classifier). Chosen sources:
  - `pr_opened`: blocker state label `ci-wait`, `human-review`, `rework`, `merging` or `done` (each implies a ready PR), or a delivered open non-draft PR (`Aiur.GitHub.DeliveredPullRequest`). Drafts do not count: an agent may open a draft before any usable code exists.
  - `pr_ci_green`: blocker label `human-review`/`merging`/`done`, or `rework` (only reached after review, which follows green), or a `passed_heads` entry in the CI lifecycle (`Aiur.CIApprovalStore`, durable across restart).
  - `pr_approved`: the standing-verdict rule already in `Aiur.GitHub.HumanReviewGate` (`approved?/2`, latest non-COMMENTED review per reviewer, no CHANGES_REQUESTED), read conditionally (ETag) only for blockers whose dependents are under `pr_approved`. GitHub `reviewDecision` is not used: it is `null` when branch protection does not require review.
  - `pr_merged`: closed `completed`, label `done`, `RecentMergeStore` merge for the ticket, or a delivered PR with `merged: true`.
  - Webhook deliveries are wake-ups and identity, never CI or review verdicts, matching `DeliveredPullRequest`'s rule.
- **KD3. A shared evidence store, written by the orchestrator, read by both gates.** The queue server and dispatch run in different processes. A small ETS-backed store holds one row per blocker ticket (`pr_number`, highest stage reached, `observed_at_ms`). The gate stays pure and never calls GitHub.
- **KD4. Trigger lookup for dispatch uses the queue hints table.** The queue already publishes per-issue rows to `:aiur_build_queue_hints` (`Hints.held?/1`). The row gains the effective trigger; a ticket with no row uses the config default.
- **KD5. Rename the gate, keep one name.** `todo_issue_blocked_by_non_terminal?/2` becomes `DispatchPolicy.todo_issue_held_by_dependency?/2`, a thin wrapper over the shared policy, and every caller moves in the same PR. A second near-identical predicate is the drift R4 forbids.
- **KD6. Changing a trigger is forward-only.** A tighter trigger does not stop running agents. A promoted but unclaimed item whose verdict falls back to waiting is withdrawn by the existing planner path, which is correct.
- **KD7. Rollout.** Default `pr_merged` changes behaviour only in the merged-but-open window (strictly earlier starts on code that is already merged). The three optimistic triggers are opt-in per queue or by config. No feature flag beyond the setting itself.

## Approaches Considered

1. **Label ladder plus durable CI/merge facts (chosen).** Zero new GitHub reads except the conditional review read for `pr_approved`. Reuses the daemon's own CI verdict. Risk: labels are agent-written; mitigated because `human-review` passes `HumanReviewGate` and `ci-wait` requires a ready PR per the agent skill.
2. **Dedicated blocker PR poll.** One batched GraphQL query per reconcile via `GithubCIPoller.poll/2`. Fresh and self-contained, but duplicates CI polling the lifecycle already does and adds a second interpretation of "green".
3. **Inversion: no trigger in the queue, only in dispatch.** Promote every member as soon as it is a queue member and let dispatch hold it. Simplest code, but `agent:todo` would no longer mean "ready", which breaks the queue panel, auto-resume and the status board's `waiting_for_dependency` count.

## Seams With Other Areas (interfaces G1 assumes or provides)

- **Provides to G2:** at dispatch, the running entry and the dispatch event carry `optimistic_blockers` (ticket ids whose edge was satisfied by a non-final stage). G2 subscribes the agent to `ticket.<blocker>.*` push events for exactly that list.
- **Provides to G3:** `Aiur.StartTrigger.final?/1` on an evidence row (merged or closed completed). G3's merge-order gate asks it for each blocker of a PR being merged.
- **Provides to G4:** edge verdict `{:failed, :pr_closed_unmerged}` and the ladder reset on a new PR number. G4 decides what happens to running optimistic dependents.
- **Provides to G5:** the same `optimistic_blockers` list, so slot priority can rank fully ready work first.
- **Assumes from none:** G1 can ship first.

## Open Questions for Kevin

- Should a draft PR count as `pr_opened`? Recommended: no; the trigger fires when the agent marks the PR ready (`agent:ci-wait`).
- Should the live run's hand-promoted waves move to an adopted queue so per-queue triggers apply? Recommended: yes for the next Build Order; the config default covers today's native-link waves.
- Should `pr_opened` ever be the config default? Recommended: no; keep `pr_merged` as default and opt in per queue until G3 and G4 land.

## Tickets

- BQ-G1-1 `plan-start-trigger-policy.md`: setting, shared policy, queue readiness.
- BQ-G1-2 `plan-blocker-progress-evidence.md`: the evidence store and its writers.
- BQ-G1-3 `plan-dispatch-gate-trigger.md`: dispatch gate on the shared policy, optimistic start record.
- BQ-G1-4 `plan-trigger-surfacing-docs.md`: CLI, waiting strings, panel, docs.

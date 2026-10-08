# MP-E1-ACC — MP-E1 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-E1-C1-T07, MP-E1-C3-T08, MP-E1-C5-T03, MP-E1-C5-T04, MP-E1-C6-T03, MP-E1-C7-T03, MP-E1-C8-T02, MP-E1-C9-T02, MP-E1-C9-T04

## Outcome

The Executor proves MP-E1 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-E1/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (41)

- MP-E1-C1-T01 — Register the queue marker label and expose Issue.queued
- MP-E1-C1-T02 — Treat the queue marker as deliberate parking in the zero-label heal and strand sweep
- MP-E1-C1-T03 — Keep open-issue labels from the existing poll and expose them through the tracker contract
- MP-E1-C1-T04 — Conditional promotion: expected_state :none on the existing state writer
- MP-E1-C1-T05 — Hints table and the DispatchPolicy rank and hold hook
- MP-E1-C1-T06 — ClaimProbe behaviour and its orchestration implementation
- MP-E1-C1-T07 — Source-scan test that keeps build_queue/ off orchestration and GitHub
- MP-E1-C2-T01 — Queue domain model and versioned JSON codec
- MP-E1-C2-T02 — Prerequisite verdicts and item readiness
- MP-E1-C2-T03 — Downstream counts and the start-order rank
- MP-E1-C2-T04 — Pure action planner (desired vs observed labels)
- MP-E1-C3-T01 — build_queue config section, state path key and their docs
- MP-E1-C3-T02 — Durable queue store that fails closed
- MP-E1-C3-T03 — Queue server - supervision, triggers, reconcile loop and Hints ownership
- MP-E1-C3-T04 — Write protocol - intents, conditional promotion, marker writes, pacing and budget pause
- MP-E1-C3-T05 — Withdrawal protocol after a dependency change (D8)
- MP-E1-C3-T06 — Competing writers - manual promotion, external hold, marker removal
- MP-E1-C3-T07 — Restart recovery and marker-based rebuild
- MP-E1-C3-T08 — Capability provider for build_queue and build_queue.build_order_source
- MP-E1-C4-T01 — ExecutorList source - ordered list with "after #N" edges
- MP-E1-C4-T02 — Build Order source - adopt a root as an optional dependency input
- MP-E1-C4-T03 — Native blocked_by of ExecutorList items through a tracker callback
- MP-E1-C4-T04 — Closed-prerequisite state_reason through a tracker callback
- MP-E1-C4-T05 — Closed-unmerged ticket PR as a failed prerequisite (webhook mode)
- MP-E1-C4-T06 — Merged PR but issue still open - grace timer and attention
- MP-E1-C5-T01 — Attention module - single Alerts caller, durable latches, Executor bindings
- MP-E1-C5-T02 — The queue attentions - failed prerequisite and the six other causes
- MP-E1-C5-T03 — Live ticket.<id>.queue.* events
- MP-E1-C5-T04 — Promoted but unauthorized - detect the dispatcher's decline
- MP-E1-C6-T01 — aiur queue show - read model, human and JSON output
- MP-E1-C6-T02 — aiur queue add/remove/reorder/hold/release with the agent-workspace guard
- MP-E1-C6-T03 — aiur queue recover and clear --remove-markers (rollback runbook)
- MP-E1-C7-T01 — Aiur.BuildProgress - progress facts, read API, change signal and milestones
- MP-E1-C7-T02 — Queue progress producer
- MP-E1-C7-T03 — Build Order progress observer
- MP-E1-C8-T01 — Read-only build-queue dashboard view with every state
- MP-E1-C8-T02 — Queue view navigation, docs page and browser check
- MP-E1-C9-T01 — Skill conventions - create waiting members with the marker; queue usage
- MP-E1-C9-T02 — Concept docs - queue states, marker, Build Order queueing
- MP-E1-C9-T03 — End-to-end acceptance (AC12) through aiurdev --test3, and a clean test reset
- MP-E1-C9-T04 — Measure queue GitHub cost and census Build Order sizes (instrumentation, no saving claimed)

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.

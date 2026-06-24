---
title: "fix: Preserve completed runs for queued drain timeouts"
type: fix
date: 2026-06-24
---

# fix: Preserve completed runs for queued drain timeouts

## Summary

Queued operator messages that are drained after a parent turn has already completed must not turn that completed run into an agent failure when the follow-up `turn/start` is never acknowledged. The fix targets the drain path called out in issue #552 rework feedback, while keeping the existing in-turn completion-race hardening.

---

## Requirements

- R1. A drained queued operator message whose initial follow-up `turn/start` times out after parent completion must not make `AgentRunner.run/3` raise or schedule an agent retry.
- R2. The affected queue item must be restored for later delivery or otherwise handled with a clear operator-visible decision, not marked failed.
- R3. Logs must include the issue id, queued request id, timeout reason, and requeue/end-cleanly decision without claiming the agent run failed.
- R4. Regression coverage must reproduce Mode B: completed parent turn, pending item drained afterward, drained `turn/start` unacknowledged, completed run remains `:ok`, no retry is scheduled.

---

## Key Technical Decisions

- **Handle at the drain seam:** `AgentRunner.run_queue_item_turn/6` owns delivered queue-item lifecycle, so it should decide whether a drained timeout is requeued or failed before the top-level runner can convert the result into a crashed agent run.
- **Limit the non-failure behavior to startup timeout reasons:** `:response_timeout` and `:turn_timeout` are the evidence-backed stale follow-up outcomes. Other queue turn errors should continue to fail the delivered item and propagate normally.
- **Keep the existing Mode A adapter hardening:** The prior callback-based requeue path still protects pending in-turn follow-ups; this rework adds the missing drain-path behavior rather than replacing that path.

---

## Implementation Units

### U1. Reproduce the drain-path race

- **Goal:** Make the regression test exercise a queued item that remains pending until after the parent turn returns completed, then loses the drained `turn/start` acknowledgement.
- **Files:** Modify `src/test/aiur/core_test.exs`.
- **Approach:** Remove the parent-turn checkpoint emission from the race test and assert the item is requeued by the drain path without agent retry state.
- **Test scenarios:** The fake Codex process acknowledges the initial turn, completes it, then ignores the drained follow-up `turn/start`; the test asserts the item is restored to pending for a later clean turn.
- **Verification:** The test fails before the `AgentRunner` fix and passes after it.

### U2. Requeue drain startup timeouts without failing the run

- **Goal:** Convert drain-path startup timeout results into a clean requeue decision.
- **Files:** Modify `src/lib/aiur/agent_runner.ex`.
- **Approach:** In the queue-item error branch, restore delivered queue items and return to the operator drain loop when the result reason is `:response_timeout` or `:turn_timeout`; leave all other errors on the existing fail-and-propagate path.
- **Test scenarios:** The Mode B regression asserts `AgentRunner.run/3` returns `:ok`, the queue item eventually drains cleanly, no orchestrator retry appears, and logs include `decision=requeue_after_parent_turn_completed`.
- **Verification:** Focused queue tests, compile with warnings as errors, and Credo pass.

---

## Scope Boundaries

- Manual TUI verification remains blocked by operator guidance until #555 lands.
- This plan does not alter orchestrator retry scheduling outside the queue-drain failure produced by this specific race.

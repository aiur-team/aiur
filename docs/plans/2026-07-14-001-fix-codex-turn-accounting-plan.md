---
title: "fix: Prevent Codex turn-accounting wedges"
type: fix
status: completed
date: 2026-07-14
---

# fix: Prevent Codex turn-accounting wedges

## Summary

Track Codex work by provider turn identity instead of counting every accepted operator request as a new anonymous turn. Exact completion notifications retire one known turn, while a thread-idle notification authoritatively retires all remaining Codex work so a completed worker can return and be replaced.

---

## Problem Frame

Codex workers can remain in `Aiur.AppServer.TurnLoop.receive_loop/2` after the provider reports the thread idle and the turn completed. Each successful operator `turn/start` response increments an anonymous counter, but repeated steering requests can refer to the same provider turn and Codex's idle/completed pair does not emit one completion signal per request. The residual count keeps the runner alive, prevents the orchestrator from parking a replaceable completed entry, and leaves later rework queued to a retired generation.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- A successful Codex `turn/start` response identifies provider work by its returned turn ID and status; multiple requests returning the same in-progress ID are steering one lifecycle, while a response that is already completed, interrupted, or failed is not demonstrably active work.
- `thread/status/changed: idle` is authoritative for aggregate Codex thread quiescence after at least one `turn/started`, while the pre-start idle guard remains necessary to reject stale startup status.
- The system-level replacement regression will use the existing orchestrator replacement path with a real controlled replacement runner, rather than introducing a second replacement mechanism or only asserting that a process was spawned.

---

## Requirements

- R1. A parent Codex turn with two or more accepted operator deliveries must exit after the provider reports all work complete.
- R2. Operator deliveries must be acknowledged exactly once only when their request is accepted by the live provider generation; pending requests at a terminal boundary must be failed for requeue rather than claimed by a retired generation.
- R3. Codex lifecycle accounting must be idempotent across duplicate or paired `turn/start` responses, `turn/started`, `turn/completed`, thread-idle, interruption, cancellation, and provider failure signals.
- R4. Distinct child turn IDs may keep the loop alive only while they remain demonstrably active; duplicate lifecycle signals for one ID must not consume another child's accounting.
- R5. A completed worker must become replaceable, and a queued rework message must be consumed by the replacement runner.
- R6. Claude counter semantics and existing pause/resume outcomes must remain unchanged.

---

## Scope Boundaries

- Do not change queue ordering, operator-message delivery policy, orchestrator admission policy, or the completed-runner replacement architecture.
- Do not switch Codex operator steering from `turn/start` to a different protocol method in this fix.
- Do not apply provider-ID tracking to Claude; preserve its existing shared counter path and completion behavior.
- Do not weaken pre-start idle suppression or reinterpret pause, cancellation, quota, and unretryable-error terminal outcomes.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/app_server/adapter.ex` seeds the parent turn's lifecycle state before entering the shared receive loop.
- `src/lib/aiur/app_server/operator_delivery.ex` correlates request IDs, invokes delivery callbacks, and currently increments `outstanding_turns` for each successful operator response.
- `src/lib/aiur/app_server/turn_state.ex` owns shared completion, interruption, pending-request failure, and zero-floor transitions.
- `src/lib/aiur/codex/turn_loop.ex` routes exact Codex `turn/started`, `turn/completed`, thread-idle, interruption, cancellation, and error notifications.
- `src/test/aiur/coding_agent_checkpoint_test.exs` provides fake-app-server lifecycle integration coverage, including Codex idle fallback and operator follow-up turns.
- `src/test/aiur/orchestrator_status_test.exs` already proves a completed runner releases capacity and an Executor message schedules a replacement while retaining FIFO queue items.

### Institutional Learnings

- `docs/refactor/feature-inventory/cdx.md` marks Codex terminal receive-loop and idle-as-completion behavior as high-risk, requiring explicit preservation of the pre-start idle guard and terminal outcomes.
- PR #575 established that pending operator requests at a parent completion boundary must fail back toward requeue instead of converting completed work into a failed run.
- The installed Codex 0.144.3 generated protocol schema requires a turn object with an ID on `turn/start`, `turn/started`, and `turn/completed`, and models thread idle separately as aggregate thread status.

---

## Key Technical Decisions

- Keep the shared integer counter as the compatibility projection, but make Codex derive it from a set of active provider turn IDs. This limits the behavior change to Codex without duplicating the receive loop.
- Seed the parent turn ID when the adapter constructs Codex loop state. Register accepted operator response IDs only while their returned status is in progress, and register `turn/started` notification IDs into the same set so response/notification order is harmless without treating already-terminal responses as active work.
- Retire exact IDs from `turn/completed`; for legacy completion payloads without an ID, retire one known turn as a compatibility fallback. Duplicate exact completions become no-ops instead of consuming unrelated child work.
- Treat post-start thread idle as authoritative aggregate completion: clear all tracked Codex IDs, fail any still-pending delivery callbacks, and return from the receive loop. A later paired completion cannot wedge or double-retire work because the worker has already crossed its terminal boundary.
- Preserve interruption, cancellation, and provider-error result routing as terminal paths; they already fail pending callbacks and leave no resident receive loop to account further signals.

---

## Implementation Units

### U1. Add identity-aware Codex turn tracking

**Goal:** Make Codex lifecycle accounting reflect unique provider work and converge at thread quiescence while leaving Claude semantics untouched.

**Requirements:** R1, R2, R3, R4, R6

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/app_server/adapter.ex`
- Modify: `src/lib/aiur/app_server/operator_delivery.ex`
- Modify: `src/lib/aiur/app_server/turn_state.ex`
- Modify: `src/lib/aiur/codex/coding_agent.ex`
- Modify: `src/lib/aiur/codex/turn_loop.ex`
- Test: `src/test/aiur/app_server/turn_state_test.exs`
- Test: `src/test/aiur/app_server/operator_delivery_test.exs`
- Test: `src/test/aiur/codex/turn_loop_test.exs`

**Approach:**
- Add an opt-in Codex tracking mode to loop-state extras, initialized with the parent turn ID by the adapter.
- Centralize turn registration, exact completion, legacy completion fallback, and authoritative idle completion in `TurnState`; retain the existing counter implementation as the default for backends without the opt-in state.
- Route successful operator responses and Codex `turn/started` notifications through idempotent registration.
- Use the returned turn status to avoid registering already-completed, interrupted, or failed response turns as active.
- Route Codex `turn/completed` through identity-aware removal and post-start idle through aggregate completion.

**Execution note:** Start with the production lifecycle sequence as a failing focused test before changing the accounting implementation.

**Patterns to follow:**
- Existing request correlation and pending-callback handling in `src/lib/aiur/app_server/operator_delivery.ex`.
- Existing pre-start idle guard and terminal routing in `src/lib/aiur/codex/turn_loop.ex`.

**Test scenarios:**
- Regression: parent ID plus two successful operator responses returning the same provider turn ID, followed by idle and completed, returns terminal success without a residual count.
- Happy path: distinct parent and child IDs remain active until exact completion notifications retire each ID.
- Edge case: a duplicate operator response/`turn/started` ID and duplicate exact completion do not increment or decrement another turn.
- Edge case: a successful operator response whose returned turn is already terminal does not create outstanding work.
- Compatibility: a legacy completion payload without an ID still makes bounded progress.
- Failure path: authoritative idle with an unresolved operator request fails its callback and terminates rather than acknowledging delivery to the retired generation.
- Regression: pre-start idle still continues, interruption still routes to pause/operator-message/error outcomes, and Claude-style states retain counter increments and decrements.

**Verification:**
- The focused state and loop tests reproduce the production accounting sequence and prove the loop returns only when no known Codex work remains.

### U2. Prove worker replacement drains rework

**Goal:** Cover the cross-layer outcome from Codex completion through orchestrator replacement and queue consumption.

**Requirements:** R1, R2, R5

**Dependencies:** U1

**Files:**
- Test: `src/test/aiur/coding_agent_checkpoint_test.exs`
- Test: `src/test/aiur/orchestrator_status_test.exs`
- Test: `src/test/aiur/core_test.exs`

**Approach:**
- Extend the fake Codex lifecycle integration to emit the production sequence: parent start, at least two operator deliveries, successful responses, idle/completed, then assert the app-server run returns.
- Strengthen completed-runner replacement coverage with an actual configured AgentRunner and deterministic fake Codex app server that claims the queued rework item, proving the item remains FIFO, is not delivered to the old generation, and drains on the new one.

**Execution note:** Keep the provider and replacement probes deterministic; do not use synthetic load or timing-only assertions.

**Patterns to follow:**
- Existing fake app-server scripts in `src/test/aiur/coding_agent_checkpoint_test.exs`.
- Existing completed-runner replacement fixture and stale-`DOWN` protection in `src/test/aiur/orchestrator_status_test.exs`.

**Test scenarios:**
- Integration: two queued operator deliveries accepted during one Codex parent lifecycle, then idle/completed, cause the run to return without timeout.
- System: an Executor rework message sent after the completed boundary kills or retires the old worker, starts a distinct replacement generation, and the replacement claims the exact queued item once.
- Edge case: a stale `DOWN` from the old generation cannot replace or retire the new runner.

**Verification:**
- The provider-sequence regression fails on the prior anonymous counter and passes with identity-aware tracking.
- The orchestrator regression observes the new generation consume the queued message and leaves no duplicate pending item or retry booking.

---

## System-Wide Impact

- **Interaction graph:** Adapter state initialization, operator-response correlation, Codex notification routing, AgentRunner completion, and orchestrator replacement remain the same call chain; only Codex's lifecycle representation changes.
- **Error propagation:** Pending requests at terminal completion still invoke their existing failure callbacks so queue items can be restored; accepted deliveries retain the existing success callback and event emission.
- **State lifecycle risks:** Out-of-order or duplicate provider events must converge by turn ID; aggregate idle must not retire a turn before the existing `turn_started?` guard is true.
- **API surface parity:** No external API, queue payload, CLI, dashboard, or tracker contract changes.
- **Integration coverage:** Focused state tests prove idempotence, fake provider tests prove receive-loop termination, and orchestrator coverage proves replacement-generation delivery.
- **Unchanged invariants:** Claude uses anonymous counter accounting; pause/resume containment, retry policy, queue FIFO, and stale-generation protection remain intact.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Older Codex payloads omit turn IDs | Keep a bounded legacy completion fallback and retain thread-idle aggregate completion. |
| Idle arrives before a delayed operator response | Fail still-pending callbacks at idle and exit; the queue item is restored instead of acknowledged to the retired generation. |
| A response and notification for the same child arrive in either order | Register both through one set-backed idempotent transition. |
| Shared `TurnState` changes alter Claude | Gate ID-set behavior on Codex opt-in state and retain focused counter tests for the default path. |
| System regression becomes timing-sensitive | Use explicit probe messages and bounded receives instead of sleeps or load. |

---

## Documentation / Operational Notes

- No user documentation or migration is required. The existing lifecycle logs remain sufficient; focused tests should name the production idle/completed sequence.
- Agent-workspace policy prohibits the real `aiurdev --test` run, so verification in this turn is limited to deterministic provider, runner, and orchestrator tests plus the scoped repository gate.

---

## Sources & References

- Issue #1162 production evidence and acceptance criteria.
- Related queue-completion hardening: issue #552 and PR #575.
- Codex lifecycle inventory: `docs/refactor/feature-inventory/cdx.md`.
- Related requirements context (Codex explicitly out of scope there): `docs/brainstorms/2026-06-14-operator-message-native-queue-requirements.md`.

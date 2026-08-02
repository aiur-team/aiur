---
title: "fix: Recover queued Codex turns after transport loss"
type: fix
status: completed
date: 2026-07-17
---

# fix: Recover queued Codex turns after transport loss

## Summary

Route closed Codex app-server writes and exact active-turn desynchronization through the existing fresh-generation replacement boundary. Preserve the claimed queue item until a healthy replacement delivers it, without broadening recovery to genuine provider failures.

---

## Problem Frame

A completed Codex turn can leave its app-server port closed just before queue drain writes the follow-up `turn/start`. The resulting Erlang `badarg`, or a later interrupt response showing a different active turn ID, currently escapes the narrow retired-port handling and converts durable queued work into a failed agent attempt.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- The orchestrator's existing clean Codex replacement path remains the sole owner of transport replacement, retry bounds, and one-writer workspace admission.
- An exact provider response naming different expected and actual active turn IDs is session-generation desynchronization. Aiur must not retarget the interrupt to the actual ID; it should restore the durable queue item and replace the stale session.
- The existing queue delivery-attempt counter is the healthy-replacement attempt boundary, so no second retry counter or in-process port restart should be introduced.

---

## Requirements

- R1. A closed Codex port during `turn/start` or interrupt must return a typed recoverable result instead of raising `ArgumentError` or booking a failed delivery.
- R2. Recoverable Codex session errors must restore, not consume or fail, the current durable queue item before the stale session exits.
- R3. Each replacement generation may claim and deliver the restored item once, preserving FIFO order and at-most-once acknowledgement.
- R4. An interrupt active-turn mismatch must never cause Aiur to send a second interrupt against the provider-reported actual turn ID.
- R5. Claude behavior, one-writer workspace ownership, and configured retry bounds must remain unchanged.
- R6. Genuine provider session/turn start failures must remain hard failures and reach the existing retry-exhaustion path.

---

## Scope Boundaries

- Do not add an in-process Codex reconnect loop or a second session supervisor.
- Do not change queue ordering, acknowledgement storage, retry budgets, workspace ownership, or tracker lifecycle policy.
- Do not reinterpret arbitrary JSON-RPC `-32600` errors as recoverable; only the exact active-turn mismatch contract qualifies.
- Do not retarget an interrupt to a provider-reported turn ID that Aiur did not intend to interrupt.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/codex/handshake.ex` already converts closed initialize, thread, account, and rate-limit writes into `:port_closed`; `start_turn/3` is the missing write boundary.
- `src/lib/aiur/agent_runner/queue_drain.ex`, `src/lib/aiur/agent_runner/turn_loop.ex`, and `src/lib/aiur/agent_runner.ex` already restore direct Codex `:port_closed` / `{:port_exit, status}` results and exit cleanly for orchestrator replacement.
- `src/test/aiur/core_test.exs` proves a replacement generation reclaims a restored queue item once while retaining workspace ownership and existing retry behavior.
- `src/lib/aiur/codex/notification_policy.ex` demonstrates strict provider-error text recognition rather than code-only matching.

### Institutional Learnings

- `docs/plans/2026-06-24-010-fix-queued-drain-race-plan.md` establishes queue drain as the settlement seam and requires startup-race work to be restored rather than failed.
- `docs/plans/2026-07-14-001-fix-codex-turn-accounting-plan.md` establishes provider turn identity as safety-critical and forbids interrupting or retiring unrelated turn IDs.
- Live #1110 evidence shows the exact mismatch shape: the requested queued turn ID differed from the provider's still-active predecessor turn ID.

---

## Key Technical Decisions

- Centralize recursive Codex recovery classification in a provider-specific policy module so queue drain, normal turn execution, and top-level runner exit agree on nested `turn_start_failed` and `turn_interrupt_failed` shapes.
- Preserve the original structured error for logging while recognizing only closed-port/port-exit transport failures and the exact expected-versus-actual active-turn mismatch response.
- Use the existing restore-then-clean-exit path to tear down the stale session. The orchestrator remains responsible for the fresh transport and bounded replacement attempt.

---

## Open Questions

### Resolved During Planning

- Should Aiur interrupt the provider-reported actual turn after a mismatch? No. That ID is not the turn Aiur intended to interrupt, so the stale session must be replaced instead.
- Should recovery retry inside the app-server adapter? No. Doing so would duplicate session ownership and queue-attempt accounting already owned by AgentRunner and the orchestrator.

### Deferred to Implementation

- The smallest exact mismatch parser belongs either beside Codex notification policy or inside the new recovery policy; choose the placement that keeps provider error recognition cohesive without widening public API.

---

## Implementation Units

### U1. Normalize recoverable Codex session failures

**Goal:** Convert closed follow-up writes and exact active-turn mismatch responses into one narrowly classified recovery contract.

**Requirements:** R1, R4, R5, R6

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/codex/session_recovery.ex`
- Modify: `src/lib/aiur/codex/handshake.ex`
- Test: `src/test/aiur/codex/session_recovery_test.exs`
- Test: `src/test/aiur/codex/handshake_test.exs`

**Approach:**
- Catch the closed-port exception at the final uncovered `turn/start` write boundary.
- Recognize direct transport losses, their existing nested turn-start/interrupt wrappers, and an exact active-turn mismatch response.
- Reject unrelated `-32600` responses and all other provider-start errors.

**Execution note:** Start with failing tests using a genuinely closed Erlang port and the production mismatch payload.

**Patterns to follow:**
- Closed-port degradation in `src/lib/aiur/codex/handshake.ex`.
- Strict no-active-turn recognition in `src/lib/aiur/codex/notification_policy.ex`.

**Test scenarios:**
- Regression: close a real port before `Handshake.start_turn/3`; the call returns `{:error, :port_closed}` without raising.
- Happy path: direct and nested closed-port/port-exit results classify as recoverable.
- Race: the exact expected/found active-turn mismatch under `turn_interrupt_failed` classifies as recoverable without producing a replacement interrupt target.
- Error path: unrelated `-32600`, malformed mismatch text, response timeout, and genuine provider rejection remain non-recoverable.

**Verification:**
- Closed writes and production mismatch evidence have stable typed outcomes; unrelated failures retain their old result shapes.

### U2. Restore queue work and replace the stale generation

**Goal:** Route all narrowly recoverable Codex session failures through existing queue restoration and clean replacement while preserving hard-failure exhaustion.

**Requirements:** R2, R3, R5, R6

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/agent_runner.ex`
- Modify: `src/lib/aiur/agent_runner/turn_loop.ex`
- Modify: `src/lib/aiur/agent_runner/queue_drain.ex`
- Test: `src/test/aiur/agent_runner_test.exs`
- Test: `src/test/aiur/agent_runner/queue_drain_test.exs`
- Test: `src/test/aiur/core_test.exs`

**Approach:**
- Replace duplicated direct transport guards with the shared Codex recovery predicate at the normal-turn and queue-drain settlement seams.
- Restore delivered work before returning the recoverable error; let top-level AgentRunner turn that Codex-only outcome into a clean exit so the orchestrator creates a fresh session.
- Retain generic failure settlement and abnormal exit for every non-recoverable start/interrupt result.

**Execution note:** Extend deterministic queue and replacement fixtures; do not use timing load or a second ad hoc retry loop.

**Patterns to follow:**
- Direct port-exit restoration branches in `src/lib/aiur/agent_runner/queue_drain.ex` and `src/lib/aiur/agent_runner/turn_loop.ex`.
- Fresh-generation, two-attempt queue assertion in `src/test/aiur/core_test.exs`.

**Test scenarios:**
- Regression: a queue item claimed after parent completion encounters a closed port on follow-up `turn/start`, returns to pending, and is delivered once by a replacement session.
- Race: an exact interrupt mismatch restores the claimed item and does not mark it failed or consumed.
- Ordering: a restored first item remains ahead of a later queued item, and each successful delivery is acknowledged once.
- Compatibility: the same error shapes on Claude retain existing failure behavior.
- Exhaustion: a genuine repeated provider-start rejection remains non-transient, so the existing orchestrator retry limit can still move the ticket to `agent:error`.

**Verification:**
- Focused queue and runner tests observe restore, distinct replacement delivery, one final consume, and unchanged hard-failure classification.

---

## System-Wide Impact

- **Interaction graph:** Codex handshake or interrupt response → adapter result → AgentRunner turn/queue settlement → clean runner exit → orchestrator replacement → restored queue claim.
- **Error propagation:** Recoverable session errors preserve their original shape for logs but restore durable work; all other errors continue through fail-and-retry handling.
- **State lifecycle risks:** The stale provider ledger dies with its session; a fresh session receives a fresh ledger, while durable queue state remains orchestrator-owned.
- **API surface parity:** No external API, CLI, dashboard, or queue payload changes; Claude remains outside the new policy.
- **Integration coverage:** Real closed-port tests cover the write boundary, focused queue tests cover settlement, and the existing controlled replacement fixture covers cross-generation delivery.
- **Unchanged invariants:** FIFO queue order, at-most-once acknowledgement, one writer per workspace, and configured retry exhaustion remain authoritative.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Recovery classification becomes too broad and masks real provider failures | Match recursive wrappers narrowly and require exact mismatch wording plus distinct IDs. |
| Mismatch handling interrupts the wrong active turn | Never expose the provider-reported actual ID as an interrupt target; replace the stale session. |
| Restored work is acknowledged twice | Reuse the existing delivered → restored → delivered → consumed queue transitions and assert delivery attempts. |
| Replacement bypasses workspace ownership or retry limits | Keep replacement entirely in the existing orchestrator/AgentRunner lifecycle. |

---

## Documentation / Operational Notes

- No user-facing documentation or migration is required.
- Agent-workspace policy prohibits a real `aiurdev --test` run; deterministic closed-port, queue, runner, and replacement tests are the verification surface for this internal transport failure.

---

## Sources & References

- Issue #1238 and live #1110/#1120 failure evidence.
- Related lifecycle hardening: `docs/plans/2026-07-14-001-fix-codex-turn-accounting-plan.md`.
- Related drain race hardening: `docs/plans/2026-06-24-010-fix-queued-drain-race-plan.md`.
- Related separation of tracker fencing: #1237.

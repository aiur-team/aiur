---
title: "refactor: Split operator message concerns"
type: refactor
status: completed
date: 2026-07-11
origin: docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md
---

# refactor: Split operator message concerns

## Summary

Split the operator-message implementation into enqueue/control, delivery-policy, and capability/queue-query concerns while preserving the existing `OperatorMessages` call surface and all runtime behavior.

---

## Problem Frame

`Aiur.Orchestrator.OperatorMessages` combines queue mutation, delivery and wake policy, and read-only capability/status projection in one 459-line module. This ticket is the downstream execution of the sibling split approved in `docs/refactor/research-arch/orchestrator-facade-finish.md`; unlike the origin planning spike, it changes implementation code while retaining that spike's zero-feature-loss and behavior-preservation contract.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input and should be reviewed during implementation and PR review.*

- Existing callers should continue using `Aiur.Orchestrator.OperatorMessages`; compatibility delegates avoid unrelated caller churn and conflicts with parallel facade work.
- Queue-update wake decisions and event-digest classification form one delivery-policy concern, while capability maps, queue depth, and pending-message projection form one read-only capabilities concern.

---

## Requirements

- R1. Separate enqueue/control, delivery-policy, and capabilities/queue-depth responsibilities along the existing concern boundary.
- R2. Preserve operator-message validation, paused/deactivated reactivation, delivery normalization, digest wake decisions, queue notifications, capability maps, and pending-message projection exactly.
- R3. Keep extracted functions as plain calls executing in the orchestrator GenServer process; introduce no process, timer, callback-order, or public caller behavior changes.
- R4. Leave the repository green with focused unit coverage at the extracted boundaries and the directly affected orchestrator integration tests passing.

---

## Scope Boundaries

- Do not alter delivery-policy semantics, accepted policies, queue priority, wake conditions, message validation, pause/resume clocks, or reactivation behavior.
- Do not change `src/lib/aiur/orchestrator.ex` or migrate sibling callers to a new public API.
- Do not refactor the seven-argument enqueue flow, alert wording, or control-message protocol beyond the moves required for the split.
- Do not modify regression tests or unrelated queue/backend behavior.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/orchestrator/operator_messages.ex` already groups enqueue, policy, and query helpers contiguously and exposes a small surface used by the facade and sibling modules.
- `src/lib/aiur/orchestrator/token_accounting.ex` and `src/lib/aiur/orchestrator/token_accounting/payloads.ex` provide the closest sibling-split precedent: the stateful owner keeps its call surface and delegates a cohesive extracted concern.
- `src/test/aiur/orchestrator_status_test.exs` pins end-to-end enqueue, delivery, digest wake, capability, and pending-message behavior; focused nested-module tests can supplement rather than duplicate it.

### Institutional Learnings

- `docs/refactor/research-arch/giant-orchestrator.md` requires plain in-process calls and verbatim preservation of orchestrator ordering invariants for every decomposition wave.
- `docs/refactor/research-arch/orchestrator-facade-finish.md` explicitly approves this split and identifies it as independent from the serialized facade waves.

---

## Key Technical Decisions

- Preserve `Aiur.Orchestrator.OperatorMessages` as the enqueue/control owner and compatibility facade so the extraction does not widen its blast radius.
- Place normalization, wake classification, comment-topic classification, and queue-update notification in `OperatorMessages.DeliveryPolicy`; these functions collectively decide how and when queued work reaches a running agent.
- Place capability projection, accepted-policy reporting, queue depth, and safe pending-message projection in `OperatorMessages.Capabilities`; these functions read state without mutating it.
- Make only the moved cross-module entry points public, retaining their clauses and return values verbatim; keep implementation-only helpers private inside their new owner.

---

## Implementation Units

### U1. Extract delivery policy

**Goal:** Move delivery normalization and queue wake/notification policy out of the enqueue owner without changing decisions or side effects.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/orchestrator/operator_messages/delivery_policy.ex`
- Modify: `src/lib/aiur/orchestrator/operator_messages.ex`
- Create: `src/test/aiur/orchestrator/operator_messages/delivery_policy_test.exs`
- Test: `src/test/aiur/orchestrator_status_test.exs`
- Test: `src/test/aiur/orchestrator_events_digest_coalesce_test.exs`

**Approach:**
- Move request normalization, queue-update notification, digest delivery options, trusted-comment/topic classification, and active-turn wake decisions as one cohesive policy module.
- Have enqueue paths and compatibility entry points call the extracted module directly while keeping process ownership and message sends unchanged.

**Execution note:** Treat this as a mechanical move first, then add focused characterization coverage for the newly callable policy boundary.

**Patterns to follow:**
- `src/lib/aiur/orchestrator/token_accounting/payloads.ex`
- Existing in-process orchestrator submodules under `src/lib/aiur/orchestrator/`

**Test scenarios:**
- Happy path: automatic delivery selects immediate only for an immediate-capable backend and checkpoint otherwise.
- Edge cases: explicit immediate and interrupt requests preserve supported, unsupported, and queue-next fallback results for every capability combination.
- Happy path: checkpoint delivery and invalid policy inputs preserve their current option/error tuples.
- Integration: sleeping or turn-idle agents are notified for immediate wake, while active-turn untrusted digests remain checkpoint-delivered and trusted actionable comments retain wake behavior.

**Verification:**
- Every original delivery-policy clause has one equivalent owner, and the existing orchestrator API produces identical queue items and worker notifications.

### U2. Extract capabilities and queue queries

**Goal:** Move read-only control capability, queue-depth, and visible-message projection into a focused module while retaining the current public facade.

**Requirements:** R1, R2, R3, R4

**Dependencies:** U1

**Files:**
- Create: `src/lib/aiur/orchestrator/operator_messages/capabilities.ex`
- Modify: `src/lib/aiur/orchestrator/operator_messages.ex`
- Move/expand: `src/test/aiur/orchestrator/operator_messages_test.exs` to `src/test/aiur/orchestrator/operator_messages/capabilities_test.exs`
- Test: `src/test/aiur/orchestrator_status_test.exs`
- Test: `src/test/aiur/orchestrator_interrupt_test.exs`

**Approach:**
- Move capability-map construction, accepted-policy selection, pending queue depth, and visible operator-message projection together.
- Retain caller-facing delegates in `OperatorMessages` so the orchestrator facade, status reporting, and interrupt logic require no edits.

**Execution note:** Preserve the existing struct-safe pending-message access as a load-bearing regression invariant.

**Patterns to follow:**
- Existing `OperatorMessages.issue_control_capabilities/2` test and snapshot regression coverage.
- The compatibility delegation used by the adjacent token-accounting sibling split.

**Test scenarios:**
- Edge case: a missing running agent reports checkpoint-only capabilities, empty checkpoints, working status, and zero depth.
- Happy path: interrupt-capable and immediate-capable running entries report the same mutually exclusive accepted-policy lists, control metadata, and accumulated queue depth as before.
- Regression: visible operator queue items project id/text/status from structs without Access-protocol crashes, with malformed text bodies retaining the empty-string fallback.
- Integration: status snapshots and pane-interrupt decisions continue to observe the same pending counts and messages through the preserved facade.

**Verification:**
- Existing callers compile unchanged, focused query tests pass, and direct integration tests retain their pre-split results.

---

## System-Wide Impact

- **Interaction graph:** The orchestrator facade and sibling modules continue calling `OperatorMessages`; only internal delegation changes.
- **Error propagation:** Delivery normalization and enqueue errors retain their exact tuples, including unsupported policies and missing agents.
- **State lifecycle risks:** Reactivate/resume ordering and queue-store replacement remain in the enqueue owner; extracted policy/query functions do not acquire state ownership.
- **API surface parity:** All existing `OperatorMessages` public functions remain available with the same inputs and outputs.
- **Integration coverage:** Existing status, digest, interrupt, deactivate, and queue tests pin the cross-module behavior after extraction.
- **Unchanged invariants:** No new process, GenServer call, timer, teardown path, or pause/resume clock mutation is introduced.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A moved helper accidentally changes clause order or fallback behavior | Preserve function bodies and clause order verbatim; compare the move mechanically and cover each delivery-policy combination. |
| Compatibility wrappers hide a missed internal dependency | Search all call sites before and after the move and compile with warnings as errors. |
| Queue wake tests rely on active-turn global state | Keep focused pure tests asynchronous where safe and rely on the existing non-async orchestrator integration tests for active-turn behavior. |
| Parallel facade work conflicts with this ticket | Avoid `src/lib/aiur/orchestrator.ex` and all unrelated sibling callers. |

---

## Documentation / Operational Notes

- No user documentation, rollout, or monitoring change is required because behavior and public interfaces remain unchanged.
- Agent workspaces prohibit the real `aiurdev --test` TUI path; focused non-manual verification is appropriate for this internal pure-move refactor.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md` (especially downstream flow F2 and refactor contract R4-R10)
- Issue-specific design: `docs/refactor/research-arch/orchestrator-facade-finish.md` §3
- Behavior-preservation invariants: `docs/refactor/research-arch/giant-orchestrator.md` §4
- Related issue: #945
- Closest precedent: #946 and PR #952

---
title: "fix: Bound coordination RPC latency"
type: fix
status: completed
date: 2026-07-12
---

# fix: Bound coordination RPC latency

## Summary

Admit blocker declarations and ordinary agent events to a dedicated asynchronous coordination queue, then return an optimistic pending response before GitHub, subscription persistence, event IDs, fan-out, or issue-log writes can delay the agent RPC.

---

## Problem Frame

Coordination tool calls currently inherit the latency of several shared disk-backed services. During bootstrap load, the side effect can complete after the caller times out, encouraging duplicate retries and loss of precise coordination signals.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- Durable `decision.requested` events remain synchronous because their caller-visible acceptance contract is intentionally stronger than best-effort coordination events.
- Admission to an in-memory supervised mailbox is the point at which ordinary coordination tools may safely report `pending`; downstream failures remain observable in logs rather than changing the already-returned RPC result.

---

## Requirements

- R1. `aiur_declare_blocker` returns promptly after its GitHub declaration and automatic subscription work is enqueued.
- R2. Ordinary `emit_event` calls, including progress, blocked, and unblocked, return promptly after publication work is enqueued.
- R3. Enqueued side effects still execute through the existing dependency, subscription, publisher, and decision-attention paths.
- R4. Tests prove RPC latency is independent of deliberately stalled downstream work.

---

## Scope Boundaries

- Keep the synchronous APIs used by non-tool publisher callers unchanged.
- Do not change explicit manual subscribe/unsubscribe or unblock behavior.
- Do not redesign GitHub retry policy, event durability, or the bootstrap load source.

---

## Key Technical Decisions

- Use a dedicated supervised GenServer as a non-blocking admission mailbox; `GenServer.cast/2` does not wait for the worker's current downstream operation.
- Start each admitted operation under the existing task supervisor so a slow dependency does not serialize later coordination jobs and task failures do not crash the queue.
- Inject the enqueue function into `ToolExecutor.build/5` tests, following the module's existing dependency-injection pattern.

---

## Implementation Units

### U1. Add asynchronous coordination admission

**Goal:** Provide a supervised queue boundary that acknowledges enqueue requests immediately and runs admitted work outside the calling process.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/coordination_tasks.ex`
- Modify: `src/lib/aiur.ex`
- Test: `src/test/aiur/coordination_tasks_test.exs`

**Approach:** Keep admission as a cast to a dedicated process. Have that process start linked-supervisor-owned tasks and log admission failures without propagating them back into completed RPCs.

**Test scenarios:**
- Happy path: enqueue a function that blocks, assert enqueue returns before release, then release it and observe completion.
- Integration: application child specs include the coordination queue in interactive and headless modes.

**Verification:** Slow work cannot delay queue admission and accepted work executes.

### U2. Move tool side effects behind the queue

**Goal:** Return pending tool results without waiting on dependency writes, subscriptions, publication, or disk markers.

**Requirements:** R1, R2, R3, R4

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/agent_runner/tool_executor.ex`
- Test: `src/test/aiur/agent_runner/tool_executor_test.exs`

**Approach:** Validate enough context synchronously to reject malformed calls, enqueue the existing side-effect chains as closures, and return a stable pending result. Preserve the durable decision request special case.

**Test scenarios:**
- Happy path: blocker declaration and generic event return successful pending responses.
- Edge case: a deliberately stalled enqueue consumer cannot keep either tool call from returning within a small bound.
- Integration: after releasing queued work, dependency subscription and event delivery still occur through existing paths.
- Error path: missing issue identity remains a synchronous tool error.

**Verification:** Tool-level tests prove bounded replies and eventual side effects.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| An async task fails after the RPC reports pending | Log failures with operation context; preserve existing idempotency so callers need not retry blindly. |
| Queue process stalls while starting a task | Cast admission still returns; each accepted operation is isolated under the task supervisor. |
| Tests assume immediate event visibility | Update only tool-boundary tests to await eventual delivery; direct publisher tests remain synchronous. |

---

## Validation Strategy

- Run focused tests for coordination admission, tool execution, publisher behavior, and application supervision with `--max-cases 4`.
- Run `mix compile --warnings-as-errors` and `mix format` from `src/`.
- Manual foreground TUI verification is operator-only under the agent-workspace guard; this backend timing change will use deterministic automated fault injection here.

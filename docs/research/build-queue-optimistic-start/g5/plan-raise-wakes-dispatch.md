---
title: Wake dispatch when max-agents is raised - Plan
date: 2026-10-09
type: fix
ticket: BQ-G5-3
priority: 2
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g5/brainstorm.md
execution: code
code_base: main at 0e5b8d0de
---

# Wake dispatch when max-agents is raised - Plan

## Goal Capsule

- Objective: a max-agents raise with ready work starts new agents on the next floor-allowed dispatch cycle, not up to one full poll interval later.
- Product authority: brainstorm R13, R14, AE8 (Product Contract unchanged).
- Open blockers: none.

---

## Problem Frame

Verified on main: a raise does add agents automatically. `Slots.apply_session_max_concurrent_agents/2` (`src/lib/aiur/orchestrator/slots.ex`) sets `session_max_concurrent_agents` at once, and `Slots.available_slots/1` uses it on the next cycle. But the call deliberately does not schedule a poll: the comment there cites #2137, when `request_refresh_state/1` ran the whole poll inline and wedged the mailbox. The next cycle therefore comes on cadence: 120 s base, 240 s with webhook widening, up to 1200 s when the fleet is idle. Since then poll reads moved to tracker tasks (`TrackerTasks.start/4` in `Dispatcher.start_poll_cycle/1`), and `Lifecycle.wake_tick/1` exists: it only moves a scheduled tick earlier, never ahead of the GitHub poll floor, and never starts polling when none is scheduled.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Use `Lifecycle.wake_tick/1`, not `request_refresh_state/1`. It respects the floor (#2365) and the no-push-back rule (#2980), and does nothing while a cycle is in flight (that cycle's end schedules the next tick).
- KTD2. Wake only when the new limit is above the old limit. A lower limit drains by attrition and needs no poll.
- KTD3. Wake on both `set` and `adjust`. A config-file raise of `agent.max_concurrent_agents` needs no wake: `Lifecycle.refresh_runtime_config/1` reads it at the start of each poll cycle, so it applies in the cycle that reads it.
- KTD4. The reply stays immediate. The wake is a timer reschedule inside the same call; no I/O.

---

## Implementation Units

### U1. Wake on raise

**Goal:** reschedule the dispatch tick when the limit rises.
**Requirements:** R13, R14; AE8.
**Dependencies:** none.
**Files:** `src/lib/aiur/orchestrator/slots.ex` (`apply_session_max_concurrent_agents/2`; update the #2137 comment), tests `src/test/aiur/orchestrator/slots_test.exs`, `src/test/aiur/orchestrator/lifecycle_test.exs`.
**Approach:** compare `Slots.max_concurrent_agent_limit/1` before and after; on increase, pipe through `Lifecycle.wake_tick/1`. Keep `StatusReport.notify_dashboard/1`.
**Test scenarios:**
- Covers AE8. State with a tick due in 240 s and last poll 30 s ago, floor 60 s: raise 16 -> 24 moves `next_poll_due_at_ms` to about 30 s from now.
- Lower 16 -> 8: tick unchanged.
- Same value: tick unchanged (existing no-op clause).
- No tick scheduled (cycle in flight): state unchanged, no timer created.
- Polling frozen: unchanged.
- `adjust +4` behaves like `set` to the same value.
- The call returns within the 5 s control budget with a slow tracker stub (no inline poll).
**Verification:** tests fail on main for the raise cases and pass after.

---

## Verification Contract

- Focused tests pass with `mix test --max-cases 4`; raise cases fail with the hunk reverted.
- Compile with warnings as errors, format, lint.
- Post-deploy (Executor): with ready work and the fleet at cap, `aiurdev set max-agents <cap+4>`; the dispatcher log shows a poll cycle start within the GitHub floor of the last poll, and new dispatches follow (subject to the envelope; see BQ-G5-2 for the ramp).

## Definition of Done

U1 merged; `website/docs-app/reference/configuration.md` or the CLI reference for `set max-agents` states that a raise takes effect on the next floor-allowed cycle; CI green on the head SHA.

## Risks

| Risk | Mitigation |
|---|---|
| Repeated raises pull polls forward and spend GitHub budget | `wake_tick/1` never schedules ahead of the floor measured from the last poll. |
| Reintroduces the #2137 wedge | No inline poll; timer reschedule only; test with a slow tracker stub. |

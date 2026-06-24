---
title: "fix: Allow max-agents drain below active count"
type: fix
date: 2026-06-24
---

# fix: Allow max-agents drain below active count

## Summary

Allow runtime `max-agents` to be lowered below the current active count without interrupting existing agents. The lower cap becomes the effective dispatch limit immediately, and status surfaces name the temporary over-cap condition as draining.

---

## Requirements

- R1. `set max-agents N` and agent-list cap decrements accept positive caps below the current active count.
- R2. Existing active agents keep running when the cap is lowered below active count.
- R3. Automatic and manual new-work dispatch stay blocked while `active + paused >= max`, so queued work does not start until active count falls below the new cap.
- R4. Status and UI surfaces expose the over-cap state as draining instead of an error.
- R5. Tests cover lowering from 4 active agents to cap 3 and dispatch blocking after one active agent exits.

---

## Key Technical Decisions

- **Drain is derived state:** Do not add a new lifecycle flag. `draining?` is true when `active > max`, which keeps the state model simple and prevents stale flags after agents finish.
- **No active interruption:** Lowering the cap only updates `session_max_concurrent_agents`. Existing agent process control stays untouched.
- **Dispatch gate remains authoritative:** Keep `available_slots/1` as the dispatch admission check. With a lower cap it already returns zero until active plus paused agents drops below the cap.

---

## Implementation Units

### U1. Accept below-active runtime caps

- **Goal:** Remove the `:below_active_count` rejection from the shared set/adjust path and return cap status with `draining?: true` when applicable.
- **Requirements:** R1, R2, R4
- **Files:** `src/lib/aiur/orchestrator.ex`, `src/test/aiur/orchestrator_max_agents_test.exs`, `src/test/aiur/orchestrator_status_test.exs`
- **Approach:** Update `apply_session_max_concurrent_agents/2`, `max_concurrent_agent_status/1`, and docs/comments around `set_max_concurrent_agents/2`.
- **Verification:** Unit tests assert 4 active agents can lower to max 3 and the returned status reports draining.

### U2. Make CLI and agent-list status show draining

- **Goal:** Print a clear drain note in `aiur set max-agents` output and render the agent-list max chip as `count/max drain` while active exceeds max.
- **Requirements:** R4
- **Files:** `src/lib/aiur/agent_control_cli.ex`, `src/lib/aiur/agent_list/app.ex`, `src/lib/aiur/agent_list/renderer.ex`, related tests
- **Approach:** Carry effective cap and drain boolean through the existing poll-state cache. Avoid synchronous orchestrator calls from the renderer.
- **Verification:** CLI and renderer tests assert visible drain wording.

### U3. Cover dispatch drain behavior

- **Goal:** Verify queued work does not dispatch after one of four active agents finishes when the cap has been lowered to three.
- **Requirements:** R2, R3, R5
- **Files:** `src/test/aiur/orchestrator_max_agents_test.exs` or an adjacent orchestrator dispatch test
- **Approach:** Use orchestrator state setup to simulate four active issues plus queued candidates, lower max to three, remove one active entry, and assert dispatch still finds no available slot until active drops below three.
- **Verification:** Targeted orchestrator tests pass.

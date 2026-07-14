---
title: "fix: Protect active turns from workspace bootstrap"
type: fix
status: completed
date: 2026-07-12
issue: 1030
---

# Protect Active Turns from Workspace Bootstrap

## Summary

Prevent lifecycle refreshes from touching a ticket workspace while an agent runner/session generation is live, and prepare genuine replacements beside the canonical checkout before swapping them into place. The change keeps the existing workspace lifecycle and warm-base architecture while closing the destructive race exposed by `todo -> in-progress` reconciliation.

---

## Problem Frame

Workspace refresh currently decides whether to recreate from tracker state and hook exit status, but it does not consult the live-turn registry. A stale `todo` view can therefore enter the destructive recreation path after a turn has already started. Materialization compounds the race by deleting the canonical destination before the replacement copy and branch checkout succeed.

## Requirements

- R1: A workspace hook or recreation must not run against a ticket checkout while that ticket has a live turn.
- R2: Turn registration and the destructive-bootstrap decision must share a per-ticket exclusion boundary so the check cannot race a new turn.
- R3: A genuine local replacement must be fully prepared at a sibling path before the canonical workspace is changed.
- R4: Failed preparation must leave the existing checkout intact.
- R5: Regression coverage must model a live turn plus a stale label-transition refresh and assert that both the turn and checkout survive.

## Scope Boundaries

### In Scope

- Local and remote before-run dispatch guarded by the existing active-turn registry.
- Per-ticket synchronization around active-turn open/close and workspace refresh decisions.
- Staged local warm-base materialization and rollback-safe directory replacement.
- Focused lifecycle, active-turn, and materialization regression tests.

### Out of Scope

- Redesigning tracker label reconciliation.
- Changing workspace naming, branch naming, or PR routing.
- Reworking coordination-tool RPC scheduling; that is tracked separately.
- Replacing the current hook contract or remote-worker provisioning model.

---

## Assumptions

- `Aiur.Opencode.ActiveTurns` remains the authoritative source for whether a ticket has a live turn.
- The existing stale `todo` recreation behavior remains valid only when no turn is active.
- A short, lock-protected rename window is acceptable once the replacement checkout is complete and no turn can acquire the workspace.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/workspace/refresh.ex` owns the dirty-leftover recreation decision table.
- `src/lib/aiur/opencode/active_turns.ex` already records active turn IDs and is consulted by operator-message delivery.
- `src/lib/aiur/agent_runner/turn_streams.ex` is the single turn open/close boundary.
- `src/lib/aiur/workspace/materialize.ex` owns warm-base copy-on-write materialization.
- `src/test/aiur/regression/workspace_lifecycle_test.exs` carries lifecycle regression coverage.
- `src/test/aiur/workspace_materialize_test.exs` covers replacement and failure behavior.

### Institutional Learnings

- Existing lifecycle fixes distinguish stale todo leftovers from legitimate in-flight WIP. This change preserves that distinction and adds live-turn presence as the stronger safety signal.
- Workspace paths are canonical join keys across the runner, logs, and UI, so replacement must preserve the canonical path rather than redirect consumers.

### External References

- None. The repository has direct, current patterns for every affected surface.

---

## Key Technical Decisions

- Hold a monitor-backed runner/session generation lease from before workspace setup through `after_run`, rather than releasing exclusion in between turns or while the session is paused.
- Keep turn registration and destructive bootstrap decisions serialized per ticket as a second boundary around the active stream itself.
- Park duplicate runners on the exact incumbent generation and terminate them only after that generation releases or its monitored owner exits.
- Stage materialization as a sibling directory, validate branch checkout there, then replace the canonical directory under the per-ticket exclusion boundary.
- Preserve and restore the old directory if the final replacement step fails; failed copying or checkout never reaches the swap.

---

## Open Questions

### Resolved During Planning

- Which live-turn signal should guard bootstrap? Use the existing `ActiveTurns` registry rather than introducing a second lock registry that could drift.
- Where should the guard live? Wrap `Workspace.Refresh` so every before-run caller receives the same behavior.

### Deferred to Implementation

- Exact helper names and cleanup logging are implementation details to settle while keeping the public workspace API stable.

---

## Implementation Units

### U1. Serialize Workspace Refresh with Active Turns

**Goal:** Ensure a live turn and a before-run refresh/recreation for the same ticket cannot overlap.

**Requirements:** R1, R2, R5

**Dependencies:** None

**Files:**

- Modify: `src/lib/aiur/opencode/active_turns.ex`
- Modify: `src/lib/aiur/agent_runner/turn_streams.ex`
- Modify: `src/lib/aiur/workspace/refresh.ex`
- Test: `src/test/aiur/agent_runner/turn_streams_test.exs`
- Test: `src/test/aiur/regression/workspace_lifecycle_test.exs`

**Approach:**

- Add a per-identifier runner/session generation lease acquired before workspace setup and held through session shutdown plus `after_run`.
- Monitor the lease owner; owner `DOWN` releases the generation and closes active turn entries that brutal termination left open.
- Add a per-identifier critical section shared by turn activation/closure and workspace refresh as a defense-in-depth boundary.
- Let refresh atomically check for active IDs while holding that critical section and return an explicit defer result without running hooks or finalizers.
- Keep different ticket identifiers independent so one slow bootstrap does not serialize the fleet.

**Execution note:** Start with the lifecycle regression that registers a turn, invokes a stale todo refresh, and proves the hook and recreation path were not entered.

**Patterns to follow:**

- Existing active-turn state queries in operator-message delivery.
- Existing `todo` versus in-progress decision-table tests in `workspace_lifecycle_test.exs`.

**Test scenarios:**

- Integration: register an active turn, invoke before-run with a todo-shaped issue, and assert the original checkout/WIP and active turn remain while the hook trace is unchanged.
- Happy path: invoke the same refresh with no active turn and assert the existing refresh/recreate behavior still runs.
- Concurrency: hold the per-ticket bootstrap section and assert turn registration waits until it is released.
- Edge case: operate on two identifiers and assert one ticket's bootstrap section does not block the other's turn registration.
- Lifecycle: close turn 1 and open turn 2 while the same runner remains alive; a duplicate stays parked across the gap and through `after_run`.
- Pause: close the active turn into input-required state and prove the duplicate stays parked for the full paused session.
- Crash: kill a generation owner with an open turn and prove monitoring closes the turn, releases the lease, and wakes the parked duplicate.

**Verification:**

- No destructive or Git-mutating before-run work executes for an identifier with an active turn.
- Existing inactive-ticket lifecycle tests retain their behavior.

### U2. Stage and Safely Replace Materialized Checkouts

**Goal:** Ensure replacement preparation cannot erase a usable canonical checkout.

**Requirements:** R3, R4

**Dependencies:** U1

**Files:**

- Modify: `src/lib/aiur/workspace/materialize.ex`
- Test: `src/test/aiur/workspace_materialize_test.exs`
- Test: `src/test/aiur/regression/workspace_lifecycle_test.exs`

**Approach:**

- Copy the warm base and establish the intended branch in a unique sibling staging directory.
- Change the canonical directory only after staging succeeds.
- Move an existing canonical directory aside, promote staging, and restore the old directory on promotion failure; clean temporary paths after success or failure.

**Patterns to follow:**

- Existing copy-on-write platform selection in `workspace/materialize.ex`.
- Existing temporary sibling cleanup conventions in workspace and agent-skill staging code.

**Test scenarios:**

- Happy path: replace an existing workspace from a warm base and assert the new checkout/branch is canonical with no staging artifacts.
- Error path: use a missing or invalid base and assert the original workspace sentinel and Git checkout remain intact.
- Error path: force checkout preparation to fail and assert staging is cleaned without touching the canonical directory.
- Integration: stale todo recreation with no active turn still yields a valid checkout and runs before-run once against the promoted replacement.

**Verification:**

- Preparation failures preserve the prior checkout byte-for-byte at the canonical path.
- Successful replacement exposes only a fully prepared checkout.

---

## System-Wide Impact

- **Interaction graph:** `AgentRunner` generation lease -> workspace setup -> `SessionLifecycle`/`TurnStreams` -> `after_run`; `ActiveTurns` owns the shared lease, active-turn registry, and owner monitor.
- **Error propagation:** Existing hook and materialization errors remain errors; active-turn skips are intentional success with explicit logging.
- **State lifecycle risks:** The primary risks are leaked leases after runner death, cross-ticket over-serialization, and failed directory promotion; owner monitoring, per-identifier keys, and rollback-focused tests address them.
- **API surface parity:** Public workspace entrypoints remain unchanged; new synchronization helpers are internal.
- **Integration coverage:** Lifecycle tests cover the tracker-state/turn/workspace crossing that isolated materialization tests cannot prove.
- **Unchanged invariants:** Ticket branch names, canonical workspace paths, remote worker paths, and stale-leftover recreation for inactive tickets remain unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A global lock stalls unrelated agents | Key critical sections by ticket identifier and test cross-ticket independence. |
| Turn registration races after the active check | Hold the same identifier lock through the full refresh/replacement operation. |
| Promotion fails after moving the old checkout | Restore the backup before returning the error and retain diagnostic logging. |
| Temporary directories accumulate after crashes | Use unique sibling names and best-effort cleanup on all handled outcomes. |

---

## Documentation / Operational Notes

- No user-facing configuration changes.
- The regression test is the acceptance signal for zero checkout replacement during a live turn; fleet-level full-cycle observation remains an operator/CI follow-up because agent workspaces cannot run the protected manual `--test` workflow.

---

## Sources & References

- Origin: GitHub issue #1030
- Related code: `src/lib/aiur/workspace/refresh.ex`, `src/lib/aiur/workspace/materialize.ex`, `src/lib/aiur/opencode/active_turns.ex`
- Prior lifecycle fixes: #577, #653

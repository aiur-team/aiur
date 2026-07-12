---
title: Fix WorkflowStore Shutdown Reads
type: fix
status: completed
date: 2026-07-12
---

# Fix WorkflowStore Shutdown Reads

## Summary

Close the race between selecting the shared workflow cache and reading it by falling back to the existing direct file load when that selected process shuts down. Add deterministic regression coverage that forces the exact shutdown window, then validate it under the ticket's coverage-concurrency conditions.

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- The production read boundary should tolerate a supervised cache shutdown because the module already treats an absent cache as a direct-load case.
- Only process-unavailable exits should trigger direct loading; unrelated call failures should retain their current failure semantics.

## Requirements

- R1. A workflow/config read in flight when `Aiur.WorkflowStore` shuts down must complete from the configured workflow file rather than exit the caller.
- R2. The fix must use deterministic process lifecycle handling without retries or arbitrary sleeps.
- R3. Existing cached reads, last-known-good behavior, and errors from direct workflow loading must remain unchanged.
- R4. Multiple coverage seeds must complete without the reported `GenServer.call(..., :current)` shutdown failure.

## Scope Boundaries

- Do not redesign the application supervision tree or serialize the full test suite.
- Do not add retry loops, polling waits, or timing sleeps.
- Do not broaden this change into unrelated `force_reload/0` semantics or test-support cleanup.

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/workflow_store.ex` already falls back to `Workflow.load/0` when the registered cache is absent, but a name lookup followed by a registered-name call leaves a shutdown race.
- `src/lib/aiur/workflow.ex` routes config consumers through `WorkflowStore.current/0` when the cache is registered.
- `src/test/aiur/extensions_test.exs` owns cache lifecycle and fallback coverage and already terminates/restarts the supervised store.
- `src/test/support/test_support.exs` restores shared singletons between tests, addressing the earlier #780 leak but not an in-flight shutdown.

### Institutional Learnings

- #589 and #780 established that tests which manipulate shared supervised children need deterministic lifecycle cleanup, while callers at an intentionally optional cache boundary must tolerate the cache being unavailable.

## Key Technical Decisions

- Call the exact PID selected during availability checking so the read cannot silently switch to a replacement process with different state.
- Catch only exits that mean the selected server disappeared during the call, then use the same direct-load fallback as the already-absent path.
- Reproduce the window with process suspension and monitored termination so the regression is scheduler-independent.

## Implementation Units

### U1. Make cached reads shutdown-safe

**Goal:** Ensure an in-flight workflow read survives the selected cache process shutting down.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/workflow_store.ex`

**Approach:**
- Consolidate the existing absent-store fallback with the in-flight process-unavailable exit path.
- Preserve all non-lifecycle call failure behavior.

**Patterns to follow:**
- Existing direct `Workflow.load/0` fallback in `Aiur.WorkflowStore.current/0`.

**Test scenarios:**
- Happy path: a live store returns its cached/reloaded workflow normally.
- Error path: a selected store shuts down before replying and the read returns the workflow loaded from disk.
- Error path: a direct load failure after shutdown remains an ordinary workflow load error.

**Verification:**
- No caller observes the reported shutdown exit from `current/0`.

### U2. Add deterministic lifecycle regression coverage

**Goal:** Exercise the exact lookup-to-call shutdown window without timing guesses.

**Requirements:** R1, R2, R4

**Dependencies:** U1

**Files:**
- Modify: `src/test/aiur/extensions_test.exs`

**Approach:**
- Block the selected store from replying, start a reader, terminate the supervised child, and assert the reader completes through direct loading.
- Restore the shared child through the existing test-support helper.

**Execution note:** Regression-first: demonstrate that the deterministic case exits on the pre-fix implementation before applying U1.

**Patterns to follow:**
- Existing monitored shared-singleton lifecycle cleanup in `src/test/aiur/extensions_test.exs` and `src/test/support/test_support.exs`.

**Test scenarios:**
- Integration: an in-flight `current/0` call overlaps supervised termination and returns the configured workflow.
- Cleanup: the test restores `Aiur.WorkflowStore` even when its assertion fails.
- Coverage concurrency: affected tests and multiple seeded coverage runs contain no `:current` shutdown exit.

**Verification:**
- The regression fails before U1 and passes after it without sleeps or retries.

## System-Wide Impact

- **Interaction graph:** All `Aiur.Config` reads transitively benefit through `Aiur.Workflow.current/0` and `Aiur.WorkflowStore.current/0`.
- **Error propagation:** Only cache-process disappearance changes from caller exit to the existing `Workflow.load/0` result.
- **State lifecycle risks:** A direct read during restart may not use the prior cache's last-known-good value; this matches the existing behavior when the cache is absent.
- **Unchanged invariants:** Cache polling, reload retries for transient parse writes, and `force_reload/0` remain unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Catching too broad an exit hides a real defect | Restrict fallback to process-unavailable lifecycle exit shapes and test the boundary directly. |
| Regression itself flakes | Coordinate with suspension/termination and process monitoring rather than wall-clock delays. |

## Sources & References

- Related code: `src/lib/aiur/workflow_store.ex`
- Related tests: `src/test/aiur/extensions_test.exs`
- Related issues: #589, #780, #962

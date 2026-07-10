---
title: "fix: Keep control commands usable under saturation"
type: fix
date: 2026-07-09
issues: [627]
status: completed
---

# fix: Keep control commands usable under saturation

## Summary

Keep the operator control surface useful while the daemon is alive but its schedulers are saturated: do not serialize a ready control command behind a rebuild, make RPC timeouts prescribe a safe recovery action, and ensure that recovery action itself cannot wait indefinitely on the daemon.

---

## Problem Frame

During a saturated Mix workload, `aiurdev agents`, `status`, and `pause` can exceed the control-RPC deadline even while the daemon and worker logs are live. The current launcher already prevents silent malformed responses, but its timeout text has no actionable fallback; additionally, the dev shim acquires the rebuild lock before checking whether its existing release is usable. The emergency `stop` path makes a direct workspace-root RPC before terminating the session, so it can itself stall under the same condition.

---

## Requirements

- R1. `agents`, `status`, and other pure control commands use a complete existing release without waiting for an unrelated rebuild lock.
- R2. A control-RPC timeout names scheduler saturation as a possible cause and tells the operator how to stop the overloaded session and its workers.
- R3. The documented stop fallback proceeds to terminate the session when its optional workspace-root lookup cannot complete.
- R4. Shell-level regression coverage proves the ready-release lock bypass, timeout guidance, and non-blocking stop fallback.

---

## Scope Boundaries

- Do not change orchestrator scheduling, worker concurrency, or RPC timeouts.
- Do not introduce a second per-agent process-management interface; degraded recovery stops the affected Aiur session.
- Do not alter normal successful control-command output.

---

## Context & Research

### Relevant Code and Patterns

- `scripts/aiurdev` classifies pure control commands and validates release completeness.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` owns RPC deadlines, direct stop teardown, and workspace process reaping.
- `packaging/npm/aiur-cli/test/launcher.test.mjs` exercises the real shell launcher against a controllable fake release.
- `src/test/scripts_aiurdev_test.exs` models dev-shim lock and ready-release behavior.

### Institutional Learnings

- `docs/plans/2026-06-24-002-fix-max-agents-control-failures-plan.md` established the marker-loss regression pattern: assert user-visible shell behavior, not only direct Elixir calls.

---

## Key Technical Decisions

- **Existing complete releases win for pure control commands:** a status/pause invocation does not need current source code, so it should not wait for a release rebuild that serves future launches.
- **`stop` is the degraded operator action:** it already kills the session, BEAM, and remaining worker processes without orchestrator cooperation; the optional metadata lookup must be bounded so teardown still starts under saturation.
- **Timeout diagnostics stay launcher-owned:** preserve the RPC status code while adding an explicit recovery instruction that applies consistently to status, agents, and pause.

---

## Open Questions

### Resolved During Planning

- Which recovery action should be documented? `aiur stop`, because it is the existing session-scoped teardown path and does not require the orchestrator to service another request once hardened.

### Deferred to Implementation

- Exact timeout budget for the optional workspace-root lookup: retain the existing control timeout unless code inspection identifies a narrower established helper boundary.

---

## Implementation Units

### U1. Bypass rebuild serialization for ready control commands

**Goal:** Allow pure control commands to execute immediately when the local release is already complete.

**Requirements:** R1.

**Dependencies:** None.

**Files:**
- Modify: `scripts/aiurdev`
- Test: `src/test/scripts_aiurdev_test.exs`

**Approach:** Check release completeness before acquiring the build lock; retain lock-based rebuild behavior only when a usable release is unavailable.

**Patterns to follow:** The existing `pure_control_command` and `release_ready` split in `scripts/aiurdev`.

**Test scenarios:**
- Happy path: a ready release executes `status` while a simulated rebuild lock exists, without waiting or invoking a rebuild.
- Edge case: an incomplete release still follows the serialized rebuild path.

**Verification:** Control commands with a ready release do not print the rebuild-lock wait message or invoke the release build.

### U2. Make timeout recovery actionable and stop non-blocking

**Goal:** Turn a saturated control timeout into a concise recovery instruction and ensure the prescribed teardown starts without depending on the saturated daemon.

**Requirements:** R2, R3.

**Dependencies:** U1.

**Files:**
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Test: `packaging/npm/aiur-cli/test/launcher.test.mjs`

**Approach:** Extend the existing timeout branch with session-stop guidance. Reuse the launcher timeout mechanism for the optional workspace-root lookup in stop, treating a failed lookup as best-effort metadata loss rather than a reason to postpone direct teardown.

**Patterns to follow:** `run_release_rpc_with_timeout`, `run_control_rpc`, and the existing shutdown cleanup sequence.

**Test scenarios:**
- Error path: `status`, `agents`, and `pause` time out, terminate their helper, retain the timeout exit status, and print the degraded recovery action.
- Integration: `stop` continues through the fake session/BEAM cleanup when its workspace-root query hangs.
- Edge case: a successful workspace-root lookup continues to enable targeted workspace process reaping.

**Verification:** Launcher tests demonstrate visible guidance and teardown progress without a responsive orchestrator.

### U3. Document the degraded operator path

**Goal:** Make the recovery action discoverable from the CLI reference.

**Requirements:** R2.

**Dependencies:** U2.

**Files:**
- Modify: `src/README.md`
- Modify: `packaging/npm/aiur-cli/README.md`

**Approach:** Add a brief note that a control timeout can indicate scheduler saturation and that `stop` terminates the affected session and workers before restart.

**Patterns to follow:** Existing command reference tables and background-session operational notes.

**Test scenarios:**
- Test expectation: none -- documentation-only behavior is covered by the launcher tests in U2.

**Verification:** Both command references describe the same degraded recovery action.

---

## System-Wide Impact

- **Interaction graph:** Dev shim → existing release → launcher control RPC; degraded timeout → direct session/BEAM/worker teardown.
- **Error propagation:** RPC timeouts retain exit code `124` while carrying a human-readable recovery action.
- **Unchanged invariants:** Normal release rebuilds remain serialized; normal successful control output and orchestration semantics are unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| A ready release races with a rebuild | Limit the bypass to the existing completeness check; incomplete releases retain the lock path. |
| Emergency stop affects more workers than the runaway one | Document it as a session-level degraded action, used only when cooperative control is unavailable. |
| Metadata lookup failure leaves a worker behind | Continue the existing tmux, BEAM, and pidfile cleanup paths even when workspace-root reaping is unavailable. |

---

## Documentation / Operational Notes

- A timeout is an operator-facing saturation signal, not evidence that the daemon is absent.
- The degraded action is session-scoped and should be followed by a fresh start.

---

## Sources & References

- Related issue: #627
- Related plan: `docs/plans/2026-06-24-002-fix-max-agents-control-failures-plan.md`
- Related code: `scripts/aiurdev`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh`

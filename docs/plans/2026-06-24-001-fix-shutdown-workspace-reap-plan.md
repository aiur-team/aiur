---
title: fix: Make shutdown workspace reap synchronous
type: fix
status: active
date: 2026-06-24
---

# fix: Make shutdown workspace reap synchronous

## Summary

Aiur shutdown will harden the cwd-scoped workspace reap with a bounded retry loop in the BEAM and a final shell-level `/proc/<pid>/cwd` backstop after the BEAM exits. The goal is that `aiurdev stop` leaves zero processes whose cwd is below the configured `workspace.root`, including agents or test children that reparent during shutdown.

---

## Problem Frame

Issue #468 reports that #458's clean-stop reap can miss one or more workspace-rooted processes under load, and follow-up issue discussion shows plain graceful stop can strand Claude RC agents as well. A single snapshot before `System.halt/1` is not enough when process parents and cwd-scoped descendants can change during teardown.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input and should be reviewed in PR review.*

- The shell backstop should use `/proc/<pid>/cwd`, matching the existing Linux-focused reap tests and production dogfood environment, rather than adding an `lsof` dependency.
- The shell should receive the configured workspace root from the BEAM through a per-run tempfile, avoiding a partial YAML parser in `aiur-engine.sh`.
- The BEAM retry loop remains best-effort and bounded; the shell backstop is the final guarantee if the BEAM is halted, killed, or starved before it can drain.

---

## Requirements

- R1. `Aiur.Shutdown.cleanup/1` must retry the cwd-scoped workspace reap until the set under `workspace.root` is empty or a small bounded retry budget is exhausted.
- R2. A process that appears under `workspace.root` after the first reap pass must still be caught before shutdown proceeds when it appears within the retry window.
- R3. The bash engine must run a final cwd-scoped sweep after the BEAM exits on both foreground trap cleanup and `aiur stop` / `aiurdev stop`.
- R4. The cwd sweep must be root-scoped and shallow-root guarded so it cannot become a host-wide process killer.
- R5. The change must preserve existing process-reaper pid reuse safeguards and avoid touching unrelated operator processes outside `workspace.root`.

---

## Scope Boundaries

- No changes to agent spawn semantics, concurrency throttling, or #465 load reduction.
- No change to workspace layout or config schema.
- No macOS-specific process discovery beyond safely no-oping where `/proc` is unavailable.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/claude/remote_control.ex` already implements cwd-scoped `/proc` discovery, shallow-root guarding, protected PID filtering, and concurrent killing.
- `src/lib/aiur/shutdown.ex` calls the workspace reap near the end of cleanup, after registered agent and serve reaps.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` already owns foreground `session_cleanup`, `cmd_stop`, BEAM-death watchdogs, and pidfile-based headless-agent reaping.
- `src/test/aiur/claude/remote_control_test.exs` and `src/test/aiur/regression/shutdown_cleanup_test.exs` contain the closest focused coverage.

### Institutional Learnings

- No `docs/solutions/` directory exists in this checkout.

---

## Key Technical Decisions

- Retry by re-snapshotting cwd-scoped PIDs rather than only waiting on the first set: the failure mode is a new or reparented process appearing during the sweep.
- Store the workspace root in a BEAM-written tempfile for the launcher: this keeps shell cleanup aligned with `Aiur.Config.workspace_root/0` without duplicating config parsing.
- Keep the shell sweep strictly under the workspace root and exclude the root itself: an operator process in the root directory should not be killed, and shallow roots are rejected.

---

## Implementation Units

### U1. Retried BEAM Workspace Reap

**Goal:** Make `RemoteControl.reap_workspace_agents/2` re-snapshot and retry until no cwd-scoped PIDs remain or the bounded sweep budget is exhausted.

**Requirements:** R1, R2, R4, R5

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/claude/remote_control.ex`
- Test: `src/test/aiur/claude/remote_control_test.exs`

**Approach:**
- Extend the existing cwd-scoped discovery loop instead of creating a separate reaper path.
- Keep existing `proc_dir`, `kill_fun`, and `protected_pids` test hooks.
- Add retry/backoff options with safe defaults and tests that use zero backoff.

**Execution note:** Start with focused tests for a PID that appears after the first kill pass and for bounded retry exhaustion.

**Patterns to follow:**
- Existing fake `/proc` helpers in `src/test/aiur/claude/remote_control_test.exs`.
- Existing `Task.async_stream/3` kill fanout in `RemoteControl.reap_all/2`.

**Test scenarios:**
- Happy path: a first-pass PID is killed, removed from fake `/proc`, and cleanup returns after the set is empty.
- Edge case: a second PID appears after the first pass and is killed on the retry pass.
- Error path: a stubborn PID that remains in fake `/proc` is retried only up to the configured bound, then returns `:ok`.
- Integration: the real-process test still kills an under-root sleeper and spares an outside-root sleeper.

**Verification:**
- Existing and new `remote_control_test.exs` coverage passes.

---

### U2. Workspace Root Handoff to Launcher

**Goal:** Have the BEAM write its configured workspace root to a per-run tempfile for shell cleanup.

**Requirements:** R3, R4

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/shutdown.ex` or application startup surface if a better existing startup hook is found
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Test: `src/test/aiur/shutdown_test.exs`

**Approach:**
- Add a best-effort write guarded by `AIUR_WORKSPACE_ROOT_FILE`.
- Export and initialize the root tempfile alongside the existing session and agent tempfiles in the engine.
- Remove the tempfile during normal cleanup after the shell sweep has consumed it.

**Patterns to follow:**
- `AIUR_SESSION_TMPFILE` and `AIUR_AGENT_TMPFILE` in the launcher.
- Best-effort tempfile behavior in `Aiur.Shutdown.truncate_session_tempfile/0`.

**Test scenarios:**
- Happy path: when the env var is set, cleanup writes the configured workspace root into the file.
- Edge case: when the env var is absent or empty, cleanup remains a no-op.
- Error path: a write failure is swallowed so shutdown can continue.

**Verification:**
- Shutdown tests pass without enabling real process reaping in test mode.

---

### U3. Bash Cwd-Sweep Backstop

**Goal:** Add a final shell sweep that kills any remaining process whose cwd is strictly under the recorded workspace root after the BEAM exits.

**Requirements:** R3, R4, R5

**Dependencies:** U2

**Files:**
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Test: `src/test/aiur/regression/shutdown_cleanup_test.exs`
- Test: `src/test/aiur_engine_test.exs` if existing engine source assertions are a better fit

**Approach:**
- Implement a Linux `/proc` scanner in bash that canonicalizes the root, refuses shallow roots, excludes protected shell PIDs, and kills discovered PIDs with TERM then KILL.
- Re-snapshot for a bounded number of sweeps with short sleeps so late reparenting is covered.
- Wire it into foreground `session_cleanup`, background watchdog cleanup, and `cmd_stop` after the BEAM kill path.

**Patterns to follow:**
- Existing `reap_aiur_agents`, `agent_pid_tree`, and `kill_beams_matching` bash helpers.
- Existing source-level regression tests for `session_cleanup`.

**Test scenarios:**
- Happy path: source assertions prove `session_cleanup`, watchdog, and `cmd_stop` call the cwd sweep after BEAM kill paths.
- Edge case: source assertions prove the sweep reads the workspace-root tempfile and removes it during cleanup.
- Error path: source assertions prove shallow-root guard exists before kill calls.

**Verification:**
- Engine regression tests pass.

---

## System-Wide Impact

- **Interaction graph:** Shutdown now has two independently scoped cleanup layers: BEAM cleanup before halt and shell cleanup after the BEAM exits.
- **Error propagation:** Both layers remain best-effort and must not prevent the CLI from exiting.
- **State lifecycle risks:** Root tempfiles must be removed at the end of shell cleanup and stale temp sweeps must continue to ignore live runs.
- **Unchanged invariants:** Registered process reaping, tmux kill-server cleanup, opencode session deletion, and pidfile-based agent reaping remain in place.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Shell cwd sweep kills too broadly | Canonical root, shallow-root guard, strict descendant match, root itself excluded |
| BEAM exits before writing root file | Write root early in cleanup and use best-effort RPC/root capture only if implementation reveals an existing safer hook |
| Retry loop slows shutdown | Keep sweep count and backoff bounded; kill fanout remains concurrent |
| Test suite accidentally kills host processes | Keep process-reaper registrations disabled in tests and use fake `/proc` for most coverage |

---

## Operational / Rollout Notes

- Post-deploy validation should run `aiurdev stop` while agents are active and check that no processes have cwd under `workspace.root`.
- Watch logs for `reap_workspace_agents` shallow-root warnings or exhausted retry warnings; either would indicate misconfiguration or an unkillable process.

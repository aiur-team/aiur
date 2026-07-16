---
title: "fix: Make shared build-gate leases sandbox-safe"
type: fix
status: completed
date: 2026-07-14
---

# fix: Make shared build-gate leases sandbox-safe

## Summary

Make local Codex turns able to write the canonical shared build-gate directory, and make Linux lease ownership independent of namespace-local PIDs. Gate setup failures will stop the requested Mix command with actionable recovery guidance instead of silently removing the fleet concurrency cap.

---

## Problem Frame

Codex `workspaceWrite` turns currently omit the daemon-exported build-gate directory. Queue publication therefore fails read-only inside the sandbox and the shell hook runs Mix outside the configured cap. The same sandbox gives independent agents identical namespace-local PIDs, so PID/PGID records can collide and appear permanently alive when interpreted from the host namespace.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- Linux hosts running the Codex PID sandbox provide `flock` and `python3` with `prctl`; a missing locking or subreaper primitive should fail closed rather than fall back to namespace-unsafe PID ownership.
- Non-Linux local hosts may retain the current PID/PGID ownership strategy because they do not expose Linux PID namespaces, while remote-worker policy and environment behavior remain unchanged.
- Existing pre-v2 lease debris cannot be proven live from an arbitrary sandbox; it should be reported with a bounded manual recovery path rather than guessed stale.

---

## Requirements

- R1. Every local Codex runtime `workspaceWrite` policy adds the canonical build-gate directory when any build-gate mode is enabled, preserving configured roots, the issue workspace, and writable Git metadata roots.
- R2. Disabled build gates and non-`workspaceWrite` policies remain unchanged; remote workers do not receive a local-host gate root.
- R3. Gate-directory preparation and shell acquisition errors fail closed within a bounded interval, identify the failed path/reason, and state how the operator can recover or deliberately disable the gate.
- R4. Linux queue and slot ownership use collision-resistant records and kernel-backed liveness that remains correct when different sandbox namespaces publish the same local PID.
- R5. A Mix descendant retains an acquired slot after its wrapper exits, while dead queue, slot-owner, and phase-owner metadata is reclaimed or reported without inflating status.
- R6. Focused integration coverage captures a real Codex `turn/start` frame, exercises parallel gated Mix commands, and covers unwritable paths, duplicate namespace-local PIDs, stale metadata, other policies/backends, and the disabled gate.

---

## Scope Boundaries

- Do not expand the gate beyond the existing local `mix compile` / `mix test` and documented `mise exec -- mix …` command surface.
- Do not add remote-worker build coordination or change remote sandbox paths.
- Do not change the independent memory-floor fail-open policy when a missing memory sample cannot bypass an already-configured build-slot cap.
- Do not redesign dispatch concurrency, scheduler caps, or phase-stagger policy.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/config/codex_sandbox_policy.ex` already appends canonical issue-workspace and writable Git roots without dropping configured roots.
- `src/lib/aiur/config.ex` resolves the per-session local versus remote Codex runtime policy and is the seam that can conditionally add a local gate root.
- `src/lib/aiur/build_gate.ex` owns the canonical gate location, exported environment, and operator status interpretation.
- `src/priv/build_gate.bash` owns queue publication, slot/phase acquisition, descendant protection, timeout, and Mix exit propagation without depending on the Aiur daemon.
- `src/test/aiur/app_server_test.exs` captures actual JSON-RPC `turn/start` frames; `src/test/aiur/build_gate_test.exs` runs the packaged hook with fake Mix/mise executables and parallel shells.

### Institutional Learnings

- `docs/plans/2026-06-24-002-fix-agent-workspace-git-metadata-plan.md` established that runtime `workspaceWrite` policies must augment, not replace, explicit roots and must pass future policy types through.
- `docs/plans/2026-07-09-001-refactor-fleet-mix-build-gate-plan.md` established that lease correctness must survive daemon and agent exits and that status metadata must not itself become capacity.
- The production incident on issue #1154 shows namespace-local PID/PGID checks are not valid host-shared liveness evidence.

### External References

- Linux `flock(2)` locks attach to an open file description, survive `fork`/`exec`, and release only after all duplicated descriptors close: https://www.man7.org/linux/man-pages/man2/flock.2.html
- Bash persistent descriptor redirections let the hook control descriptor lifetime while executed commands inherit the calling shell's descriptors: https://www.gnu.org/software/bash/manual/html_node/Redirections.html

---

## Key Technical Decisions

- **Prepare the gate root before a local Codex turn:** Canonicalize, create, and probe the configured directory before adding it to `writableRoots`. Return a structured startup error when the host path is invalid or unwritable instead of sending a frame that cannot honor the gate.
- **Augment only enabled local `workspaceWrite` policies:** Feed the canonical gate root through the existing append-unique policy machinery. Remote and future/non-write policy shapes retain their current contract.
- **Use holder-owned advisory locks as Linux liveness proof:** A held file descriptor is kernel-global across PID namespaces. A dedicated subreaper owns it, launches Mix, and retains it until detached descendants exit. PID/PGID fields remain diagnostic only and never decide Linux reclamation or status.
- **Publish queue identity atomically:** Generate unique queue/owner candidates with exclusive temporary creation, lock before publication, and rename into visibility. Identical namespace-local PIDs therefore cannot collide.
- **Fail closed on coordination failures:** Missing Linux lock support, directory/record publication failures, invalid ownership state, and phase-lock errors return a stable nonzero status without invoking Mix. The transcript names the recovery action; timeouts keep their existing bounded status.
- **Treat legacy metadata conservatively:** Automatically remove unlocked v2 metadata. Report pre-v2 slot/phase records as blocking legacy debris until the operator confirms no old build is running and clears it, avoiding false liveness decisions from host PID 2 or PGID 1.

---

## Implementation Units

### U1. Add the canonical gate root to Codex turn policy

**Goal:** Make enabled local Codex sandboxes writable at the exact shared directory the shell hook uses, with host-side preflight and unchanged remote/disabled behavior.

**Requirements:** R1, R2, R3, R6

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/build_gate.ex`
- Modify: `src/lib/aiur/config.ex`
- Modify: `src/lib/aiur/config/codex_sandbox_policy.ex`
- Test: `src/test/aiur/workspace_and_config_test.exs`
- Test: `src/test/aiur/app_server_test.exs`

**Approach:**
- Expose enabled-state and canonical writable-root preparation from the build-gate module, including a create/write probe with structured recovery-oriented errors.
- Pass the prepared local root as an additional runtime writable root only for enabled local Codex sessions.
- Reuse append-unique normalization so user roots, issue workspace, and in-workspace Git metadata retain their order and no duplicates are introduced.

**Execution note:** Start with the captured `turn/start` frame and runtime-policy error cases so the sandbox contract is proven before changing lease internals.

**Patterns to follow:** `Aiur.Config.CodexSandboxPolicy.resolve_runtime/4`, `Aiur.PathSafety.canonicalize/1`, and the app-server JSON frame fixtures.

**Test scenarios:**
- Integration: an enabled local Codex session with an explicit user root emits a `workspaceWrite` frame containing that root, the canonical workspace/Git roots, and the canonical gate root exactly once.
- Happy path: the default local policy adds the canonical gate root and creates/probes a previously absent directory.
- Edge case: capacity, memory, and stagger settings all count as enabled modes; all-zero/nil settings leave the policy unchanged.
- Error path: a configured regular-file or unwritable gate path returns a bounded structured startup failure before `turn/start`.
- Compatibility: non-`workspaceWrite` policies pass through, and a remote policy retains raw remote workspace/Git roots without the local gate root.

**Verification:** Captured local `turn/start` frames match the environment's canonical `AIUR_BUILD_GATE_DIR`, while disabled/remote frames preserve their prior shapes.

---

### U2. Replace Linux PID leases with collision-safe lock ownership

**Goal:** Preserve the configured cap and accurate status across PID namespaces, process exits, descendants, and stale metadata.

**Requirements:** R3, R4, R5, R6

**Dependencies:** U1

**Files:**
- Modify: `src/priv/build_gate.bash`
- Modify: `src/lib/aiur/build_gate.ex`
- Modify: `src/lib/aiur/agent_control_cli.ex`
- Test: `src/test/aiur/build_gate_test.exs`
- Test: `src/test/aiur/agent_control_cli_test.exs`

**Approach:**
- On Linux, hold queue, numbered-slot, and phase ownership with advisory locks on persistent descriptors; record random publication tokens plus diagnostic namespace-local PID/PGID values.
- Hand each acquired slot descriptor to a dedicated subreaper even when the invoking shell enabled `varredir_close`; the holder launches Mix, reports its status, and releases only after adopted descendants exit.
- Determine Linux status from lock contention, remove unlocked v2 queue/owner metadata, and surface legacy or unreadable metadata as a degraded status instead of counting host-visible PID collisions as active.
- Retain the existing PID/PGID strategy only for non-Linux hosts, and make missing Linux lock/subreaper support or any coordination-write failure fail closed with a stable status and recovery message.

**Execution note:** Extend the fake Mix harness first with deterministic local-PID overrides and descendant processes; avoid synthetic CPU load.

**Patterns to follow:** Existing hard-link atomic publication, bounded timeout handling, fake Mix/mise integration, and concise `aiur_build_gate`/`BUILD GATE` status signals.

**Test scenarios:**
- Happy path: direct and mise-wrapped Mix commands acquire/release a Linux lock and preserve the real command status.
- Integration: more parallel shells than capacity never exceed the configured number of concurrently-running fake Mix commands.
- Namespace edge case: two concurrent shells publish the same diagnostic local PID but receive distinct queue identities and serialize correctly at capacity one.
- Descendant edge case: with `varredir_close` initially enabled, a real Mix VM exits after spawning a detached child; the subreaper keeps the slot active until that child exits.
- Recovery: unlocked queue/slot-owner/phase-owner metadata is removed and omitted from counts; a currently locked owner remains active even when its diagnostic PID is `2` or PGID is `1`.
- Legacy recovery: pre-v2 records produce one actionable degraded status and block admission rather than being guessed live or stale.
- Error paths: unwritable directories, failed candidate publication, missing Linux `flock`/`python3`, and unavailable phase ownership do not run fake Mix and return the documented gate-failure status promptly.
- Compatibility: disabled gating installs no hook; a forced non-Linux strategy retains PID/PGID descendant behavior.

**Verification:** Lock contention, status, and fake Mix timing agree on live capacity without consulting Linux PIDs, and every gate-structure error is fail-closed.

---

### U3. Document safe recovery and operational contract

**Goal:** Give operators a concise way to diagnose and recover an unavailable or legacy gate without accidentally bypassing the fleet cap.

**Requirements:** R3, R5

**Dependencies:** U1, U2

**Files:**
- Modify: `SPEC.md`
- Modify: `src/README.md`
- Modify: `website/docs-app/reference/configuration.md`
- Modify: `.aiur/examples/config.example`

**Approach:**
- Specify that enabled local Codex `workspaceWrite` frames include the canonical gate directory and that coordination errors fail the requested Mix command.
- Document the stable error status, status diagnostics, restart/re-dispatch requirement, and safe legacy-debris recovery sequence after confirming no old Mix process is active.
- Document the deliberate full opt-out: set both build settings to `0` and omit `min_free_memory_mb`; do not use it as an automatic fallback for errors.

**Patterns to follow:** Existing configuration reference tables and adjacent build-cap/start-stagger operational notes.

**Test scenarios:**
- Test expectation: none — this unit changes explanatory contract text and examples; behavior is covered in U1/U2.

**Verification:** The config reference and runbook identify both recovery options: repair/clear the gate and retry, or explicitly disable every admission mode with awareness that the fleet safeguards are removed.

---

## System-Wide Impact

- **Interaction graph:** Local Codex policy resolution prepares and grants the same path that `AgentEnvironment` exports; Codex and Claude shell commands continue to share the Bash gate, while remote workers remain outside it.
- **Error propagation:** Host preflight errors stop Codex session startup with structured context; shell coordination errors return a stable nonzero command status; underlying Mix statuses remain unchanged after acquisition.
- **State lifecycle risks:** Kernel lock lifetime replaces cross-namespace PID guesses. Metadata becomes advisory and reclaimable; a subreaper deliberately extends slot lifetime across detached descendants.
- **API surface parity:** Only Codex has an OS sandbox frame to augment. Other local backends keep the shared hook and fail-closed lease behavior without receiving Codex-specific policy changes.
- **Integration coverage:** A captured JSON-RPC frame proves policy wiring, while parallel real shells prove the cap rather than only testing map helpers.
- **Unchanged invariants:** Ordinary shell commands, remote-worker paths, disabled gate configuration, memory admission semantics, and non-`workspaceWrite` policies retain their current behavior.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Linux runtime lacks `flock` | Detect before acquisition, fail closed with one recovery message, and document the dependency/opt-out rather than use PID fallback. |
| Descriptor is accidentally explicitly unlocked while a descendant remains | Release by closing only the wrapper descriptor and cover the descendant case with a real child process. |
| Legacy and new clients overlap during rollout | Treat old records as blocking, require fleet restart/re-dispatch, and document cleanup only after confirming no old Mix work is live. |
| Status observation races with release | Base counts on nonblocking lock probes; only remove metadata after acquiring its unlocked record, and keep observation best-effort. |
| Gate root broadens Codex write access | Add only the canonical configured gate directory when the gate is enabled; preserve stricter non-`workspaceWrite` modes. |

---

## Documentation / Operational Notes

- The recovery text must avoid advising ad hoc deletion while old builds may still hold pre-v2 leases.
- Operators changing gate settings or clearing legacy records should restart/re-dispatch agents because their environment and sandbox policy are captured at process start.
- Focused tests should model namespace PID duplication deterministically rather than launching privileged namespace/load harnesses in CI.

---

## Sources & References

- Origin issue: #1154
- Existing policy plan: `docs/plans/2026-06-24-002-fix-agent-workspace-git-metadata-plan.md`
- Existing build-gate plan: `docs/plans/2026-07-09-001-refactor-fleet-mix-build-gate-plan.md`
- Related code: `src/lib/aiur/config/codex_sandbox_policy.ex`, `src/lib/aiur/build_gate.ex`, `src/priv/build_gate.bash`
- Linux lock semantics: https://www.man7.org/linux/man-pages/man2/flock.2.html
- Bash descriptor semantics: https://www.gnu.org/software/bash/manual/html_node/Redirections.html

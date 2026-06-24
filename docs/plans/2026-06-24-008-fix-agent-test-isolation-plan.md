---
title: "fix: Block unsafe agent manual test runs"
type: fix
date: 2026-06-24
---

# fix: Block unsafe agent manual test runs

## Summary

Agent issue workspaces must not launch `scripts/aiurdev --test` or `--test3` against the live GitHub sandbox tickets. The safest current behavior is to fail closed before reset or launch when an agent workspace invokes manual test mode, while preserving normal operator-root smoke runs and non-test agent workspace commands.

---

## Problem Frame

During live dogfood, nested manual test runs from issue workspaces reset pinned sandbox tickets, re-added live dispatch labels to #99, and rendered the production backlog in the foreground TUI. Prior per-instance identity work isolates tmux socket/session names, but the agent workspace test shim still permits a reset path that mutates real tracker state before the isolated runtime can protect the operator.

---

## Requirements

### Agent Workspace Safety

- R1. `scripts/aiurdev --test` and `scripts/aiurdev --test3` must refuse to run from an agent workspace before any reset, stop, clear, build, or engine launch side effect.
- R2. The refusal message must clearly say manual test mode is blocked in agent workspaces because it can mutate live sandbox tracker tickets, and it must direct operators to run from the repo root or a dedicated harness.
- R3. Non-test agent workspace commands, including ordinary run/control paths, must continue to use the local IR sandbox where that behavior already exists.

### Operator Smoke Runs

- R4. `scripts/aiurdev --test` and `--test3` from a normal operator checkout must keep the existing reset and launch behavior.
- R5. Manual run documentation must stop instructing agents to wait on hard-coded `aiur-orangekid` identities and must tell them to derive the actual socket/session from launcher output or exported identity.

### Regression Coverage

- R6. Tests must prove agent workspace manual test mode exits before `mix aiur.test.reset`, `aiurdev stop`, log clearing, port pinning, or engine execution.
- R7. Tests must keep existing operator `--test` and non-test agent workspace behavior covered.

---

## Key Technical Decisions

- **Fail closed in the dev shim before sandbox setup:** The live failure happens before the release can enforce policy, because the shim performs reset and stop work first. Put the guard immediately after argument parsing and before `enable_agent_ir_sandbox`, `ensure_built`, `stop`, clear, or reset code.
- **Block only manual test mode in agent workspaces:** Agent workspaces still need normal run/control commands for development and cleanup. The unsafe path is specifically `--test` / `--test3`, because those flags reset pinned GitHub sandbox tickets and prepare dispatch labels.
- **Treat socket derivation as documentation/runtime output, not a new identity system:** The engine already exports per-instance `AIUR_TMUX_SOCKET` and `AIUR_TMUX_SESSION`. Update the runbook to consume those instead of restoring legacy hard-coded names.

---

## Implementation Units

### U1. Add pre-side-effect manual test guard

- **Goal:** Refuse `--test` and `--test3` from detected agent workspaces before any destructive setup runs.
- **Requirements:** R1, R2, R3, R4.
- **Files:** `scripts/aiurdev`, `src/test/scripts_aiurdev_test.exs`.
- **Approach:** After parsing flags and validating `--port`, call `in_agent_workspace_tree` once. If the marker is present and either test flag is set, print the fail-closed message and exit with usage error status. Otherwise keep the existing agent IR sandbox path for non-test commands.
- **Test scenarios:** Agent workspace `--test` exits non-zero without invoking fake `mise` reset or fake engine; agent workspace `--test3` behaves the same; non-test agent workspace launch still enters IR sandbox.
- **Verification:** Targeted script shim tests cover the blocked and preserved paths.

### U2. Preserve operator test reset behavior

- **Goal:** Ensure the new guard does not regress normal operator-driven smoke runs.
- **Requirements:** R4, R7.
- **Files:** `src/test/scripts_aiurdev_test.exs`.
- **Approach:** Keep the existing outside-agent `--test` test as the compatibility check and adjust only expectations made obsolete by the block.
- **Test scenarios:** Operator checkout `--test` still invokes `mix aiur.test.reset --single`, clears normal logs, and does not pass `--test` to the engine.
- **Verification:** Existing test remains green with updated neighboring tests.

### U3. Update manual-test runbook identity guidance

- **Goal:** Remove stale hard-coded socket/session instructions from the agent-facing runbook.
- **Requirements:** R2, R5.
- **Files:** `AGENTS.md`, `src/README.md`.
- **Approach:** Document that agent issue workspaces cannot run manual test mode directly. For operator/root smoke runs, instruct users to read `AIUR_TMUX_SOCKET` / `AIUR_TMUX_SESSION` or the launcher/session output and substitute those values in `tmux -L ... -t ...` commands.
- **Test scenarios:** Test expectation: none -- documentation-only change.
- **Verification:** Grep confirms the active runbook no longer presents `aiur-orangekid` as the canonical socket for current foreground runs.

---

## Scope Boundaries

- Do not redesign the GitHub sandbox ticket reset flow in this issue; closed-ticket reset idempotence is already planned separately.
- Do not change per-instance identity derivation in the shared launcher engine.
- Do not add a new external manual-test harness in this issue. The current safe behavior is to block agent-workspace manual test attempts before tracker mutation.

---

## Sources & Research

- `scripts/aiurdev` owns `--test` / `--test3` parsing, reset invocation, log clearing, and agent IR sandbox setup.
- `src/lib/aiur/agent_environment.ex` already marks child workspaces with `AIUR_AGENT_WORKSPACE` and comments that destructive commands must be refused.
- `src/test/scripts_aiurdev_test.exs` contains the shim contract tests for operator `--test`, agent IR sandboxing, and port handling.
- `docs/plans/2026-06-24-007-fix-test-reset-closed-tickets-plan.md` covers the related but separate closed-ticket label reset behavior.

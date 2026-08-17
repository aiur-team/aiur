---
title: "fix: Surface executor command diagnostics"
date: 2026-08-16
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Surface Executor Command Diagnostics

## Goal Capsule

- **Objective:** Ensure `executor-answer` and `executor-escalate` always give operators the actionable diagnostic produced by the daemon, or contextual transport-failure details when no diagnostic exists.
- **Authority:** GitHub issue #2054 and the repository's established control RPC marker contract.
- **Stop conditions:** Both executor mutations preserve application errors across RPC, silent failures name the attempted decision/version/endpoint, focused regression coverage asserts stderr text, and operator documentation explains remedies.
- **Tail ownership:** Complete the scoped local gate, draft PR self-review, and CI handoff against `main`.

---

## Product Contract

### Summary

Executor Commands can park tickets and idle the fleet, so their mutation CLI must distinguish invalid input, stale state, scope rejection, and daemon reachability instead of collapsing them into a blank exit code.

### Requirements

- R1. A missing or invalid answer field must name the corresponding CLI flag and the remedy.
- R2. A stale expected version must report the current version.
- R3. An Executor-scope rejection must name the offending field and direct the operator to `executor-escalate`.
- R4. Application diagnostics from both executor mutations must cross the guarded RPC/launcher boundary and appear on process stderr.
- R5. A genuinely silent transport failure must name the decision ID, expected version, and daemon endpoint.
- R6. An unreachable daemon must remain distinct from an application rejection.
- R7. Operator documentation must describe the failure classes and remedies.

### Scope Boundaries

- Preserve the existing command arguments, exit codes, and control marker protocol.
- Do not change DecisionStore validation or Executor answer authorization policy.
- Do not generalize unrelated CLI error formatting beyond what the shared wrapper contract requires.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Inject the existing `AgentControlCLI.control_error/1` marker writer into `ExecutorCommandCLI` through an error callback while retaining direct stderr as the standalone default. This follows `BuildOrdersCLI` and avoids relying on remote `:standard_error`, which the RPC evaluator does not return reliably.
- KTD2. Keep application and transport diagnostics separate: marker-prefixed daemon errors are surfaced verbatim, while only truly empty wrapper failures receive the attempted decision/version/endpoint context.
- KTD3. Map known `answer_invalid` fields to CLI vocabulary, including `--idempotency-key`; retain an actionable inspected fallback for future validation fields.

### Sequencing

Implement daemon-side error injection and formatting first, then prove the cross-language marker seam and silent transport context, then update CLI documentation.

---

## Implementation Units

### U1. Preserve executor application diagnostics

- **Goal:** Carry executor mutation failures through the control RPC marker protocol.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** None.
- **Files:** `src/lib/aiur/executor_command_cli.ex`, `src/lib/aiur/agent_control_cli.ex`, `src/test/aiur/executor_command_cli_test.exs`.
- **Approach:** Add an injectable error writer to the executor CLI, pass the control marker writer from guarded RPC entrypoints, and add precise `answer_invalid` clauses plus a future-safe field fallback.
- **Patterns to follow:** `Aiur.BuildOrdersCLI` error injection and `Aiur.AgentControlCLI.control_error/1`.
- **Test scenarios:** Missing idempotency data names `--idempotency-key`; stale versions include the current version; Executor-scope rejection includes the field and `executor-escalate`; both answer and escalation can emit through an injected marker writer.
- **Verification:** Direct CLI tests fail if diagnostics are printed only to an unobserved stream or lose their remedies.

### U2. Diagnose silent launcher failures with command context

- **Goal:** Preserve marked daemon diagnostics and contextualize only genuinely empty executor mutation failures.
- **Requirements:** R4, R5, R6.
- **Dependencies:** U1.
- **Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `src/test/aiur/regression/engine_control_test.exs`, `src/test/aiur_engine_test.exs`.
- **Approach:** Give executor mutation calls a scoped attempt description, include it and the resolved release node in no-output wrapper messages, and extend the existing cross-language regression matrix to the two commands.
- **Execution note:** Start with regression assertions on stderr contents; an exit-code-only assertion does not prove this fix.
- **Patterns to follow:** Existing `__AIUR_CONTROL_ERROR__` parsing, `run_control_rpc_captured/4`, and silent-failure-shape coverage.
- **Test scenarios:** A marked answer error appears verbatim on stderr without protocol markers or the generic fallback; silent answer and escalation failures name decision/version/endpoint; a down node uses the existing not-running diagnostic; ordinary argument validation still names the missing flag.
- **Verification:** The launcher tests demonstrate nonzero stderr for both underlying diagnostics and genuinely empty transport failures.

### U3. Document operator remedies

- **Goal:** Make executor mutation recovery discoverable from the CLI reference.
- **Requirements:** R7.
- **Dependencies:** U1, U2.
- **Files:** `website/docs-app/reference/cli.md`.
- **Approach:** Add concise failure-mode guidance beside the existing executor command rows, covering missing fields, stale versions, scope escalation, and daemon reachability.
- **Test expectation:** None -- documentation mirrors behavior proven by U1 and U2 tests.
- **Verification:** Every documented remedy names the exact command or flag the operator should use.

---

## Verification Contract

- Compile Elixir with warnings treated as errors.
- Format all touched Elixir files and confirm formatting is clean.
- Compute and run the deterministic affected-test set with `--max-cases 4`.
- Run the focused executor CLI and engine regression files explicitly if the affected-test mapper does not include both.
- Attempt the required real CLI manual verification once; if the agent-workspace guard blocks `--test`, record that exact guard rather than constructing an alternate harness.

---

## Definition of Done

- All R1-R7 behaviors are implemented without changing the public command surface.
- Tests assert diagnostic stderr content, not only nonzero exits.
- The focused local gate passes and no abandoned experimental code remains.
- A draft PR against `main` accurately describes the pushed diff and is self-reviewed before CI handoff.

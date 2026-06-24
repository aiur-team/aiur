---
title: "fix: Max agents control failures"
type: fix
date: 2026-06-24
origin: docs/brainstorms/2026-06-23-background-control-plane-consistency-requirements.md
issues: [524]
---

# fix: Max agents control failures

## Summary

Make `aiur set max-agents N` either apply the runtime cap with the expected success message or fail with a concrete, operator-actionable reason.

---

## Problem Frame

During a live background dogfood run, `scripts/aiurdev status` and `scripts/aiurdev agents` could reach the node while `scripts/aiurdev set max-agents 3` exited `1` with no stdout or stderr. Existing Elixir code already validates the cap and prints clear application-level messages, so the remaining risk is the launcher RPC wrapper losing or suppressing output when the control expression does not produce a marker or when stderr is flattened by the release RPC command.

---

## Requirements

- R1. A successful `aiur set max-agents N` against a running node prints `aiur: max-agents set to N (... active)` and exits with the control marker code.
- R2. Invalid input and below-active caps exit nonzero with a visible reason.
- R3. RPC transport failures and malformed control responses print the underlying output when present and add a fallback explanation when no output is available.
- R4. Regression coverage exercises the shell command path, not only direct Elixir module calls.

---

## Key Technical Decisions

- **Preserve application-level validation in `Aiur.AgentControlCLI`.** `AgentControlCLI.set_max_agents/1` and `Orchestrator.set_max_concurrent_agents/2` already cover success, invalid caps, and below-active rejection. The fix should avoid duplicating those rules in shell.
- **Make marker loss explicit in `run_control_rpc`.** A successful release RPC that does not include `__AIUR_CONTROL_EXIT__:<code>` should not fail silently. The wrapper should forward any captured output and add a clear malformed-response line when the marker is absent.
- **Test the real launcher command shape.** The regression should drive `aiur set max-agents N` through `packaging/npm/aiur-cli/libexec/aiur-engine.sh` with the fake release binary so quoting, marker parsing, and stderr propagation are all covered.

---

## Implementation Units

### U1. Harden control RPC output handling

- **Goal:** Ensure `run_control_rpc` prints a diagnostic when release RPC succeeds but the control marker is missing or malformed.
- **Requirements:** R2, R3.
- **Dependencies:** none.
- **Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `packaging/npm/aiur-cli/test/launcher.test.mjs`.
- **Approach:** Keep the existing transport-failure branches, but make the marker-success branch treat missing markers as a malformed control response. Forward non-marker output first, then print a fallback line that names the node and expression class without leaking confusing shell internals.
- **Patterns to follow:** Existing `run_control_rpc` marker parsing and control RPC tests in `packaging/npm/aiur-cli/test/launcher.test.mjs`.
- **Test scenarios:** fake release RPC emits success output and marker; fake release RPC emits application failure marker; fake release RPC exits `0` with stderr/stdout but no marker; fake release RPC exits `0` with no output and no marker.
- **Verification:** Launcher tests prove the command exits nonzero and stderr is never empty for missing-marker responses.

### U2. Cover `set max-agents` through the launcher

- **Goal:** Add shell-level coverage for the exact `set max-agents` command, including success and application-level rejection.
- **Requirements:** R1, R2, R4.
- **Dependencies:** U1.
- **Files:** `packaging/npm/aiur-cli/test/launcher.test.mjs`, `src/test/aiur/agent_control_cli_test.exs`.
- **Approach:** Reuse the fake release setup for `run_control_rpc`, extend it to model `Aiur.AgentControlCLI.set_max_agents(N)`, and assert the launcher invokes that expression and propagates the success or rejection output. Keep the existing Elixir tests as the application-level contract.
- **Patterns to follow:** Existing launcher tests for `pause --all` and `AgentControlCLI.set_max_agents/1` tests.
- **Test scenarios:** `set max-agents 3` prints the expected success line; `set max-agents 1` propagates below-active stderr and exits nonzero; invalid shell input still exits `64` before RPC.
- **Verification:** Targeted Node launcher tests plus existing Elixir `AgentControlCLI` tests pass.

---

## Scope Boundaries

- Do not change max-agent scheduling semantics.
- Do not redesign the distributed-node readiness or identity work from the background control-plane plan.
- Do not add a second validation path for below-active caps in shell.

---

## Risks & Dependencies

- The release RPC command may merge remote stdout and stderr differently across environments. Tests should assert operator-visible output, not the internal stream boundary, except for launcher-owned error lines.
- Overly verbose malformed-response output could confuse normal application failures. Only the no-marker path should get the new fallback message.

---

## Sources / Research

- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` contains `run_control_rpc` and `cmd_set`.
- `src/lib/aiur/agent_control_cli.ex` contains `set_max_agents/1` and the control exit marker.
- `src/lib/aiur/orchestrator.ex` contains `set_max_concurrent_agents/2` and below-active rejection.
- `packaging/npm/aiur-cli/test/launcher.test.mjs` already models release RPC transport failures.
- `docs/brainstorms/2026-06-23-background-control-plane-consistency-requirements.md` requires consistent failure classification across `pause`, `resume`, `message`, and `set`.

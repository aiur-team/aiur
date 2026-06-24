---
status: active
type: fix
created: 2026-06-24
issue: 482
---

# fix: Isolate agent aiurdev IR test runs

## Problem

Agent workspaces inherit enough of the operator environment that `scripts/aiurdev
--test` / `--test3` can still touch operator-owned runtime state before the
existing Elixir reset guard fires. The current failure mode is destructive:
`--clear` can delete `~/.aiur/logs`, `stop` can target the wrong runtime if
identity leaks, and the reset task refuses too late for the operator's active run.

Authoritative issue comments from @its-everdred revise the original "always
refuse agents" fix: agents should be able to run the real IR dev-test path, but
only inside an isolated identity/state/log/tmux sandbox.

---

## Scope

**In:** `scripts/aiurdev` ordering and sandbox environment, the reset guard's
safe-agent distinction, opencode bridge port isolation, and focused regression
tests. **Out:** creating new GitHub sandbox tickets per agent; the existing
`.aiur-test-tickets.json` reset remains the test reset source of truth.

### Deferred to Follow-Up Work

- Update the long-form AGENTS.md non-TTY recipe to derive socket/session names
  from `AIUR_TMUX_SOCKET` / `AIUR_TMUX_SESSION` or the engine `__identity` probe
  instead of hard-coding `aiur-$USER`.
- Fully remove the need for shared GitHub sandbox tickets by adding a true
  per-agent local tracker fixture.

---

## Requirements

- R1. Agent-workspace `--test` / `--test3` must establish isolated state, logs,
  runtime pidfiles, tmux identity inputs, and bridge/dashboard ports before
  `--clear`, engine `stop`, or `mix aiur.test.reset`.
- R2. The reset task must continue blocking direct unsafe agent-workspace reset
  calls that did not pass through the sandboxed shim path.
- R3. Operator-launched `scripts/aiurdev --test` outside an agent workspace must
  keep its existing behavior.
- R4. Regression tests must prove agent-workspace test launch does not clear
  `~/.aiur/logs`, does not call the operator identity, and still reaches the
  test reset only after the sandbox marker is set.

---

## Implementation Units

### U1. Sandbox the shim before destructive test side effects

**Goal:** Detect agent-workspace `--test*` runs early and export local sandbox
paths before any clear/stop/reset side effect.
**Files:** `scripts/aiurdev`, `src/test/scripts_aiurdev_test.exs`, `.gitignore`.
**Approach:** Parse dev-test flags before `ensure_built`. When `--test` or
`--test3` is present and either `AIUR_AGENT_WORKSPACE`, `AIUR_REPO_ROOT`, or
`PWD` indicates `/aiur-workspaces/`, export sandbox-local `AIUR_BG_STATE_DIR`,
`AIUR_COOKIE_FILE`, `AIUR_PROFILES_FILE`, `AIUR_LOGS_ROOT`, `XDG_RUNTIME_DIR`,
and `AIUR_AGENT_IR_SANDBOX=1`. Clear only the sandbox log parent and inject
`--port 0` unless the caller supplied a port.
**Test scenarios:** agent marker path preserves real `HOME/.aiur/logs`; fallback
path detection via `AIUR_REPO_ROOT`; operator path still clears the supplied
home logs.
**Verification:** Focused script tests pass.

### U2. Keep unsafe reset blocked while allowing shim-sandboxed reset

**Goal:** Preserve defense in depth for direct `mix aiur.test.reset` calls from
agent workspaces while allowing the properly sandboxed shim path through.
**Files:** `src/lib/aiur/test_reset.ex`, `src/test/aiur/test_reset_test.exs`.
**Approach:** Treat `AIUR_AGENT_IR_SANDBOX=1` as the proof that `scripts/aiurdev`
already established the local sandbox. Without it, keep blocking both the env
marker and path-pattern cases.
**Test scenarios:** direct agent-workspace reset remains blocked; sandbox marker
allows dry-run validation against a temp repo.
**Verification:** Focused reset tests pass.

### U3. Isolate the opencode bridge port for nested IR runs

**Goal:** Avoid the remaining default bridge-port collision when an agent starts
an interactive nested run.
**Files:** `scripts/aiurdev`, `src/lib/aiur/opencode/config.ex`,
`packaging/npm/aiur-cli/libexec/aiur-engine.sh`, tests.
**Approach:** Derive a stable high port from the agent workspace path and export
`AIUR_OPENCODE_BRIDGE_PORT`; let explicit env/config override continue to work.
Ensure the engine re-exports the variable into the tmux pane launcher.
**Test scenarios:** config reads the env override; script output shows an
agent-local bridge port and no operator log deletion.
**Verification:** Focused opencode config and script tests pass.

---

## Risks

- A hash-derived bridge port can still collide with an unrelated local process.
  Mitigation: use a high per-workspace range and preserve explicit env override.
- Allowing reset from agent workspaces is only safe after the shim marker is set.
  Mitigation: reset task still refuses direct calls without `AIUR_AGENT_IR_SANDBOX`.
- Moving flag parsing before build can accidentally change normal command flow.
  Mitigation: keep `build` special-cased first and cover existing forwarding tests.

---

## Verification

- `mise exec -- mix test test/scripts_aiurdev_test.exs`
- `mise exec -- mix test test/aiur/test_reset_test.exs test/aiur/opencode/config_test.exs`
- `mise exec -- mix compile --warnings-as-errors`
- `mix format --check-formatted`
- Manual CLI verification should run only after the focused tests prove
  agent-workspace `--test*` is scoped to `.aiur-agent-ir/`.

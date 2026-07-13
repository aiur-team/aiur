---
title: "fix: Resolve slot providers for ticket sessions"
type: fix
status: completed
date: 2026-07-13
---

# fix: Resolve slot providers for ticket sessions

## Summary

Launch each OpenCode serve with its slot workspace as the explicit custom config directory, while retaining the ticket workspace as the session directory. Add a real-serve regression proving the slot's Aiur model remains available when provider lookup is scoped to a different session directory.

---

## Problem Frame

Aiur creates OpenCode sessions in ticket workspaces for useful file-picker/sidebar behavior, but OpenCode resolves providers per request directory. The slot's `opencode.json` therefore disappears from model resolution when an operator sends a TUI prompt, producing `ProviderModelNotFoundError` even though the model is registered in the slot.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- Preserve ticket-workspace session directories and use OpenCode's supported custom-config directory precedence instead of changing file-picker/sidebar scope.
- A focused real-serve test is acceptable in the affected test set because CI installs the repository's pinned OpenCode version through mise.

---

## Requirements

- R1. Operator prompts for a ticket-scoped session resolve the slot's on-demand `aiur/issue-<identifier>` model without `ProviderModelNotFoundError`.
- R2. The session retains the ticket workspace while provider configuration remains isolated to the owning slot.
- R3. Warm/sentinel identifiers and tokens remain confined to the slot configuration; no config is copied into ticket workspaces.
- R4. Regression coverage exercises provider resolution when the session/request directory differs from the slot config directory.
- R5. The final acceptance handoff identifies the required operator-root wrapper-tmux drive because destructive `--test` runs are guarded inside agent workspaces.

---

## Scope Boundaries

- Do not change session writer lifecycle, model registration, transcript replay, or attach-pane selection.
- Do not create per-ticket `opencode.json` files or share configuration between slots.
- Do not add Build Orders or address unrelated OpenCode reliability work.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/opencode/server.ex` already owns the slot workspace when spawning the serve process and is the narrowest place to apply a per-process environment override.
- `src/lib/aiur/opencode/session_writer_registry.ex` deliberately creates sessions with ticket-workspace directories; that behavior should remain unchanged.
- `src/lib/aiur/agent_environment.ex` demonstrates the repository's established `Port.open/2` environment tuple shape.
- `src/lib/aiur/opencode/workspace_setup.ex` remains the single owner of slot-local provider/model materialization.

### Institutional Learnings

- No matching `docs/solutions/` entry covers provider resolution across differing OpenCode session and serve directories.

### External References

- OpenCode v1.17.10 config loading appends `OPENCODE_CONFIG_DIR` to directory sources and loads its `opencode.json` after project discovery: `packages/opencode/src/config/config.ts` and `packages/opencode/src/config/paths.ts` in the repository's pinned upstream tag.

---

## Key Technical Decisions

- Set `OPENCODE_CONFIG_DIR` only in the spawned serve's environment, pointing to that serve's slot workspace. This preserves slot isolation and gives every directory-scoped request the owning slot's provider configuration.
- Keep the session creation `directory` query unchanged so file-picker/sidebar behavior continues to use the ticket workspace.
- Exercise the actual pinned OpenCode serve and `/provider?directory=...` behavior in regression coverage; an assertion over port options alone would not prove the external resolution contract.

---

## Open Questions

### Resolved During Planning

- Should sessions move to slot directories? No. OpenCode's custom config directory supports separating provider lookup from the ticket-scoped session directory.
- Should slot config be copied or linked into ticket workspaces? No. Multiple slots can host the same ticket, so ticket-local config would leak slot tokens and break isolation.

### Deferred to Implementation

- Exact test cleanup timing for the spawned serve should follow the existing `Aiur.Opencode.Server` shutdown behavior and be adjusted if the real process exposes a deterministic race.

---

## Implementation Units

### U1. Bind each serve to its slot config directory

**Goal:** Make directory-scoped session prompts resolve the owning slot's Aiur provider without changing the session's ticket workspace.

**Requirements:** R1, R2, R3, R4

**Dependencies:** None

**Files:**

- Modify: `src/lib/aiur/opencode/server.ex`
- Test: `src/test/aiur/opencode/server_test.exs`

**Approach:**

- Add the slot workspace as `OPENCODE_CONFIG_DIR` in the environment of only the OpenCode serve child process.
- Build the regression from separate temporary slot and ticket directories. Materialize the slot config/model, boot the real pinned serve, create or address a ticket-directory session, and assert provider discovery for that directory includes the slot's `aiur/issue-<identifier>` model.
- Stop the serve and remove temporary state through deterministic test cleanup.

**Execution note:** Start with the failing real-serve regression so the test demonstrates the current directory/config mismatch before the launch environment changes.

**Patterns to follow:**

- `Aiur.AppServer.Adapter.start_port/2` and `Aiur.AgentEnvironment.workspace_env/1` for Port-compatible environment tuples.
- Existing `Aiur.Opencode.WorkspaceSetup` and `Aiur.Opencode.ApiClient` APIs for configuration and session setup.

**Test scenarios:**

- Integration: materialize `issue-99` in a slot directory, boot the serve, use a distinct ticket directory for session/provider lookup, and assert the `aiur` provider exposes `issue-99`.
- Isolation: assert the ticket directory does not receive an `opencode.json`, proving resolution came from the slot config source rather than copied state.
- Lifecycle: stop the test serve after the assertion without leaving an OpenCode child process.

**Verification:**

- The regression fails on the pre-fix launch behavior and passes when the slot directory is explicitly configured.
- Existing slot, session writer registry, and no-leak tests continue to pass unchanged.

---

## System-Wide Impact

- **Interaction graph:** Slot boot still materializes configuration before `Server.start_link/1`; only the serve process environment changes before directory-scoped provider requests and TUI prompts.
- **Error propagation:** Serve startup and HTTP errors retain their existing shapes.
- **State lifecycle risks:** Slot rebuilds already launch a fresh serve after rematerializing the same workspace, so each generation receives the current slot config and token.
- **API surface parity:** Session creation and caller APIs remain unchanged.
- **Integration coverage:** The real-serve regression covers the OpenCode config precedence that Elixir-only unit tests cannot prove.
- **Unchanged invariants:** Slot-local tokens/models, on-demand registration, ticket session directories, and per-serve session writers are preserved.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A repository project config overrides the slot provider | OpenCode 1.17.10 loads `OPENCODE_CONFIG_DIR` after project config; the regression uses a differing request directory to lock this precedence. |
| The integration test leaks a serve process | Register cleanup immediately after boot and assert the server process terminates. |
| A future OpenCode pin changes config precedence | The real-serve regression fails against the newly pinned binary before release acceptance. |

---

## Documentation / Operational Notes

- No user-facing documentation change is required; this restores the documented TUI operator-message path.
- Operator-root manual acceptance must open ticket #99 in the real wrapper-tmux `--test` run, send a message, and observe agent prose or tool events without the model-not-found error.

---

## Sources & References

- Related issue: #1075
- Related code: `src/lib/aiur/opencode/server.ex`, `src/lib/aiur/opencode/session_writer_registry.ex`, `src/lib/aiur/opencode/workspace_setup.ex`
- External source: https://github.com/anomalyco/opencode/blob/v1.17.10/packages/opencode/src/config/config.ts
- External source: https://github.com/anomalyco/opencode/blob/v1.17.10/packages/opencode/src/config/paths.ts

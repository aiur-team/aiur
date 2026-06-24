---
title: fix: Clarify background tmux stale-session handling
type: fix
status: active
date: 2026-06-24
---

# fix: Clarify background tmux stale-session handling

## Summary

Background mode already skips the Elixir UI tree, but the shell launcher still uses one detached tmux session to own the release BEAM lifetime. This plan keeps that lifetime mechanism, adds explicit stale-session recovery before `new-session`, and documents the exact boundary between headless orchestration and tmux supervision.

---

## Requirements

- R1. `aiur --bg` must not start UI-only Elixir children: no `Aiur.Tmux`, pane manager, agent list input/app, pane supervisor, or dashboard unless explicitly opted in.
- R2. A pre-existing live background session must not fall through to tmux's opaque `duplicate session` error.
- R3. A pre-existing stale tmux session for this instance should be cleaned up before retrying background startup.
- R4. The docs must state which tmux resource background mode still uses and why.

---

## Scope Boundaries

- Do not replace tmux as the background BEAM lifetime holder in this PR.
- Do not change foreground interactive session behavior.
- Do not change agent backend selection, opencode bridge behavior, or control RPC contracts.

---

## Context & Research

### Relevant Code and Patterns

- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` creates the tmux session, exports `AIUR_TMUX_*`, waits for control liveness, and owns cleanup/watchdog behavior.
- `src/lib/aiur.ex` already gates the supervised tree with `headless?: true`, retaining orchestration/backends while skipping UI-only children.
- `src/test/aiur/application_test.exs` already verifies app-level headless gating.
- `packaging/npm/aiur-cli/test/launcher.test.mjs` is the focused test surface for shell launcher resource selection and failure messages.

### External References

- None. The behavior is repo-local launcher orchestration.

---

## Key Technical Decisions

- Keep one detached tmux session for background process lifetime now: the engine's watchdog and cleanup paths are already coupled to that session and pidfile, so removing tmux entirely is larger than this acceptance slice.
- Treat an existing session as a first-class state before calling `new-session`: live control plane means "already running"; missing control plane means "stale tmux state" and cleanup/retry.
- Preserve `--bg --interactive` as the opt-in path for an attachable background UI stack.

---

## Implementation Units

### U1. Preflight Existing Background Sessions

**Goal:** Replace opaque duplicate-session failure with explicit live-or-stale handling before `tmux new-session`.

**Requirements:** R2, R3

**Dependencies:** None

**Files:**
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Test: `packaging/npm/aiur-cli/test/launcher.test.mjs`

**Approach:**
- Add a pre-`new-session` check for the instance tmux session.
- If a session exists and the control RPC is live, exit with a direct "already running" message and point users at `aiur status` / `aiur stop`.
- If a session exists but the control RPC is not live, kill the stale session, reap recorded agents when possible, kill the instance BEAM by node name, and then continue to create a fresh session.
- Keep the existing orphaned-BEAM reap path for the no-session case.

**Patterns to follow:**
- Existing `wait_for_session_startup`, `probe_control_liveness`, `reap_aiur_agents`, and `kill_beams_matching` helpers in `packaging/npm/aiur-cli/libexec/aiur-engine.sh`.

**Test scenarios:**
- Error path: fake tmux reports `has-session` success and fake control reports live; `--bg` exits before `new-session` with a clear already-running message.
- Recovery path: fake tmux reports `has-session` success and fake control reports down; `--bg` kills the stale session and then creates a fresh session.
- Regression path: no existing session preserves normal background startup behavior.

**Verification:**
- Launcher tests cover live-session guidance and stale-session cleanup.

### U2. Document Background Resource Model

**Goal:** Make the current background-mode resource boundary obvious to operators.

**Requirements:** R1, R4

**Dependencies:** U1

**Files:**
- Modify: `AGENTS.md`
- Modify: `src/README.md`
- Modify: `packaging/npm/aiur-cli/README.md`

**Approach:**
- Update run docs to say background mode is headless inside the BEAM but still starts one detached tmux session as the BEAM lifetime holder.
- State that no interactive agent-list panes, chat panes, prewarm panes, or dashboard are started unless explicitly requested.
- Include the stale-session recovery behavior and the operator action for a genuinely live existing session.

**Patterns to follow:**
- Existing run-command tables in `AGENTS.md`, `src/README.md`, and `packaging/npm/aiur-cli/README.md`.

**Test scenarios:**
- Test expectation: none -- documentation-only change.

**Verification:**
- Docs accurately match the launcher and app supervision behavior.

---

## System-Wide Impact

- **Interaction graph:** The change is limited to launcher startup before the release BEAM starts; app supervision and agent runtime paths remain unchanged.
- **Error propagation:** Live duplicate state becomes a deliberate launcher error; stale duplicate state becomes cleanup plus retry.
- **State lifecycle risks:** Cleanup must remain instance-scoped so one Aiur project cannot kill another keyed project session.
- **Unchanged invariants:** Foreground starts still attach tmux UI; background starts still wait for the control plane before reporting success.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Killing a valid tmux session whose control RPC is temporarily slow | Only classify stale after probing control on an already-existing session before startup; a live control plane exits without cleanup. |
| Hiding a real launcher regression behind cleanup | Only cleanup the already-existing tmux session path; fresh `new-session` failures still print captured startup output. |
| Docs overstate tmux removal | Explicitly document the remaining tmux lifetime session instead of claiming zero tmux dependency. |

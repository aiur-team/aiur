---
title: "fix: Refresh stale agents after main updates"
type: fix
date: 2026-06-24
---

# fix: Refresh stale agents after main updates

## Summary

Stop active agents when the default branch advances, then refresh clean existing workspaces before the next turn. This closes the gap where an already-running agent keeps using stale manual-test instructions or scripts after a safety fix lands.

---

## Problem Frame

The `scripts/aiurdev --test` guard blocks fresh latest-main agent workspaces, but live evidence on #560 and #561 showed two remaining failures. A pre-fix active workspace can run old scripts before it sees the guard, and a fresh agent can waste turns retrying copied `/tmp` harnesses after the guard tells it manual test mode is blocked. The fix must reach active agents through the running control plane and make the allowed verification path unambiguous.

---

## Requirements

- R1. A default-branch push must interrupt or stop active agents so they cannot continue executing stale checkout behavior after `main` changes.
- R2. The next turn for a stopped active issue must refresh a clean existing workspace from `origin/main` before the agent resumes.
- R3. Dirty workspaces must not be silently overwritten during refresh; they should fail with actionable output rather than discard user or agent edits.
- R4. Agent prompts and runbooks must state that blocked manual test mode is terminal for the agent turn: do not clone, copy, or use `/tmp` harnesses to retry it.
- R5. Operator-root manual `scripts/aiurdev --test` and `--test3` runs must keep working.

---

## Key Technical Decisions

- **React to `system.<default>.branch.push` in the orchestrator:** The firehose and ls-remote ticker already publish system branch pushes independent of agent checkouts. Subscribing there lets the running daemon stop active agents even when their workspaces are stale.
- **Restart by releasing claims, not by force-merging in-process:** Terminating running entries frees capacity and lets the normal active-issue poll redispatch them. This reuses existing lifecycle cleanup and avoids inventing a second restart path.
- **Refresh only clean workspaces in the hook:** The existing `before_run` hook is the right place to update a reused checkout. A dirty workspace is a real handoff problem; failing the hook is safer than merging over in-flight edits.
- **Treat `/tmp` harness retries as instruction failures:** The shim guard already blocks copied harnesses through the workspace marker. The prompt and docs should tell agents to stop after that guard instead of trying alternate directories.

---

## Implementation Units

### U1. Stop active agents on default-branch pushes

- **Goal:** Make a default branch push end all currently working agents so they cannot continue with stale checkout code or runbooks.
- **Requirements:** R1, R5.
- **Files:** `src/lib/aiur/orchestrator.ex`, `src/test/aiur/orchestrator_deactivate_test.exs`.
- **Approach:** Subscribe the orchestrator to `system.*.branch.push`, classify default-branch push topics, and terminate working entries without workspace cleanup. Leave paused and human-review deactivated entries alone because they are not executing.
- **Patterns to follow:** Existing `ticket.*.branch.push` subscription and parser helpers in `src/lib/aiur/orchestrator.ex`.
- **Test scenarios:** A `system.main.branch.push` topic parses as the default branch; applying it to two working entries removes them, kills their task pids, clears claims, and preserves workspaces; non-default system pushes are ignored; ticket branch pushes still use the blocker auto-resume path.
- **Verification:** Focused orchestrator tests prove the stop policy and parser behavior.

### U2. Refresh clean existing workspaces before resumed turns

- **Goal:** Ensure a redispatched agent starts from a checkout that includes the latest default-branch safety fixes when it is safe to update.
- **Requirements:** R2, R3.
- **Files:** `.aiur/hooks`.
- **Approach:** In `before_run`, when the workspace is a valid git worktree, fetch `origin main`, verify the worktree is clean, and fast-forward or merge `origin/main` into the current issue branch. If the worktree is dirty, print a clear error and fail the hook so Aiur does not restart stale work silently.
- **Patterns to follow:** The existing guarded reclone shape in `.aiur/hooks`; avoid the old unguarded wipe behavior.
- **Test scenarios:** A clean existing workspace advances to `origin/main`; an invalid workspace still reclones; a dirty existing workspace exits non-zero with guidance instead of changing files.
- **Verification:** Hook smoke through shell-level checks or a focused workspace hook test.

### U3. Make blocked manual-test paths unambiguous for agents

- **Goal:** Stop agents from retrying `--test` through copied harnesses or clones after the guard blocks direct agent-workspace manual testing.
- **Requirements:** R4, R5.
- **Files:** `src/prompts/shared-agent-instructions.md`, `.aiur/prompt.md`, `.aiur/examples/prompt.md.example`, `AGENTS.md`, `src/AGENTS.md`, `src/test/aiur/prompt_builder_test.exs`, `src/test/scripts_aiurdev_test.exs`.
- **Approach:** Add agent-facing wording that a blocked manual-test guard is a stop condition for that turn, not a signal to clone elsewhere. Tighten the shim refusal text to include the same instruction. Keep operator-root instructions intact and preserve socket/session derivation guidance.
- **Patterns to follow:** Existing shared prompt sections for repo-specific operational rules and current shim tests that assert refusal text.
- **Test scenarios:** Prompt builder output includes the no-retry instruction; shim blocked output includes no alternate-harness guidance; operator `--test` compatibility tests remain green.
- **Verification:** Focused prompt and shim tests pass.

---

## Scope Boundaries

- Do not redesign pinned GitHub sandbox tickets or create a new local tracker fixture in this issue.
- Do not make Aiur merge dirty workspaces automatically.
- Do not remove operator-root manual TUI verification; only agent-workspace manual-test attempts are blocked.

---

## Risks & Dependencies

- Stopping all working agents on every default-branch push is conservative. It can interrupt useful work, but the alternative is allowing stale safety behavior to keep running after main changes.
- Dirty workspaces may need operator intervention before resuming. The hook should make that state obvious rather than silently leaving the workspace stale.
- Existing active daemons only get this protection after this change itself is running; the fix protects subsequent safety-critical main updates.

---

## Sources & Research

- `src/lib/aiur/events/github_firehose.ex` and `src/lib/aiur/events/ls_remote_ticker.ex` already publish `system.<branch>.branch.push`.
- `src/lib/aiur/orchestrator.ex` already consumes event topics for reactivation, pause requests, and ticket-branch auto-resume.
- `.aiur/hooks` owns existing workspace bootstrap and currently does not refresh valid worktrees.
- `scripts/aiurdev` already blocks latest-main agent-workspace `--test` / `--test3`; this plan handles stale active agents and retry behavior around that guard.

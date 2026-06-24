---
title: "fix: Ensure agent workspaces have writable git metadata"
type: fix
date: 2026-06-24
execution: code
---

# fix: Ensure agent workspaces have writable git metadata

## Summary

Codex turns should receive a sandbox policy that always grants write access to the actual issue workspace, even when workflow config supplies an explicit `workspaceWrite` policy for additional roots or network access.

---

## Problem Frame

Live agents reported `ORIG_HEAD.lock` and branch movement failures because their runtime sandbox policy did not necessarily include the workspace path where `.git` lived. The local dogfood config currently sets explicit Linux writable roots, which bypasses the default workspace-derived policy on macOS workspaces.

---

## Requirements

- R1. Local Codex sessions using a `workspaceWrite` turn policy include the actual agent workspace in `writableRoots`.
- R2. Explicit non-`workspaceWrite` or future sandbox policy shapes still pass through unchanged.
- R3. Remote worker policies keep remote workspace paths raw instead of local-canonicalizing them.
- R4. Regression coverage proves git metadata writes such as `ORIG_HEAD` and index writes succeed in a bootstrapped issue workspace.

---

## Key Technical Decisions

- **Augment only `workspaceWrite`:** Aiur should add the runtime workspace to `writableRoots` when the policy type is `workspaceWrite`, preserving support for unknown Codex policy types.
- **Normalize in both config paths:** The local Codex adapter uses `Aiur.Codex.Config.runtime_settings/1`, while remote workers use `Aiur.Config.codex_runtime_settings/2`; both paths need identical workspace-root augmentation.
- **Test git behavior with real git commands:** A regression test should run `git fetch`, write `ORIG_HEAD`, update the index, commit, and push to a local bare remote so the issue is covered at the Git level rather than only by map assertions.

---

## Implementation Units

### U1. Normalize workspace-write policies

- **Goal:** Ensure runtime `workspaceWrite` sandbox policies contain the actual workspace root.
- **Files:** Modify `src/lib/aiur/config/schema.ex`, `src/lib/aiur/codex/config.ex`; test in `src/test/aiur/workspace_and_config_test.exs`, `src/test/aiur/codex/config_test.exs`, `src/test/aiur/app_server_test.exs`, and `src/test/aiur/core_test.exs`.
- **Approach:** Add the workspace root to `writableRoots` when policy type is `workspaceWrite`; preserve ordering and avoid duplicate roots. Keep unknown policy types unchanged.
- **Patterns to follow:** Existing runtime sandbox tests near `Schema.resolve_runtime_turn_sandbox_policy/3` and app-server payload tests that capture JSON frames.
- **Test scenarios:** Explicit local `workspaceWrite` with a non-workspace root gains canonical workspace root; remote `workspaceWrite` gains the raw remote workspace; future policy maps pass through unchanged.
- **Verification:** Captured `turn/start` payloads include the agent workspace in `sandboxPolicy.writableRoots`.

### U2. Cover real git metadata writes

- **Goal:** Prove a bootstrapped issue workspace supports normal git operations without API workarounds.
- **Files:** Modify `src/test/aiur/workspace_and_config_test.exs`.
- **Approach:** Create a local bare remote and source repo, materialize an issue workspace through `after_create`, resolve its runtime sandbox policy, and run git commands that write fetch metadata, `ORIG_HEAD`, the index, commits, and push refs.
- **Patterns to follow:** Existing workspace bootstrap tests that create temporary git repositories and hooks.
- **Test scenarios:** `git fetch` writes `FETCH_HEAD`; `git update-ref ORIG_HEAD HEAD` writes `ORIG_HEAD`; `git add`/`git commit` writes index and object metadata; `git push` updates a branch on the local remote.
- **Verification:** The test passes using real `git` commands inside the workspace.

---

## Scope Boundaries

- Do not copy this checkout's `.git` directory or create a `.git-writable` sidecar for the current workspace.
- Do not hardcode macOS or Linux host paths into committed dogfood config.
- Do not change the Codex app-server protocol for non-`workspaceWrite` sandbox policy types.

---

## Risks & Dependencies

- Adding the workspace root to explicit `workspaceWrite` policies broadens write access relative to a deliberately narrow policy. The requested agent workspace behavior requires that access, and non-workspace policy types remain available for stricter configurations.

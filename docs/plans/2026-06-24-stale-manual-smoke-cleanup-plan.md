---
title: Reap Stale Manual Smoke Aiur Nodes
type: fix
date: 2026-06-24
---

# Reap Stale Manual Smoke Aiur Nodes

## Summary

Add launcher-level cleanup for stale same-user manual-smoke Aiur release nodes, wrapper tmux sessions, and orphaned `opencode attach` processes. Keep the cleanup bounded to Aiur identities and old issue workspaces so active daemon runs and unrelated BEAMs are spared.

---

## Problem Frame

Aborted foreground/manual `scripts/aiurdev --test` verification can leave release BEAM nodes and wrapper-driven `opencode attach` processes running after the operator stops the main daemon. The existing cleanup reaps the current instance well, but it does not inventory old issue-workspace release nodes or abandoned wrapper sessions left by failed manual-smoke attempts.

---

## Requirements

- R1. Startup preflight must detect same-user stale Aiur release BEAMs from old issue workspaces and print node names, workspace roots, and a suggested cleanup command without exposing cookies or token material.
- R2. `aiur stop` or a documented cleanup command must list and reap stale Aiur release nodes by instance identity without killing unrelated BEAMs.
- R3. Cleanup must include abandoned manual-smoke wrapper tmux sessions and orphaned `opencode attach` children that are not part of a live Aiur daemon.
- R4. Cleanup must prefer graceful RPC or TERM before force kill.
- R5. Regression coverage must prove an aborted manual-smoke path leaves no release BEAM behind.

---

## Key Technical Decisions

- **Launcher-owned cleanup:** Implement stale cleanup in `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, because startup, foreground cleanup, and `stop` already resolve node names, tmux sockets, and process reaping there.
- **Identity-first reaping:** Match Aiur BEAMs by same-user command lines containing `-name aiur-$USER...@127.0.0.1` plus Aiur release paths. Avoid release-dir-only killing because sibling keyed instances may share a dev release directory.
- **Wrapper cleanup through tmux inventory:** Treat wrapper sockets with Aiur manual-smoke naming patterns as candidates only when they are stale or abandoned, and kill their server before reaping remaining process descendants.
- **Focused tests over manual `--test`:** Agent workspaces cannot run manual `--test`; cover the cleanup path with shell-source and shim regression tests, and report manual TUI verification as blocked in this environment.

---

## Implementation Units

### U1. Shared stale process inventory and cleanup

- **Goal:** Add sourceable engine helpers that inventory stale same-user Aiur release BEAM nodes and reap them with TERM then KILL.
- **Files:** Modify `packaging/npm/aiur-cli/libexec/aiur-engine.sh`; test in `src/test/aiur/regression/shutdown_cleanup_test.exs`.
- **Patterns:** Follow `kill_beams_matching`, `reap_aiur_agents`, `sweep_dead_tmux_sockets`, and `sweep_stale_tmp_artifacts`.
- **Test scenarios:** Source assertions confirm node/root output, TERM before KILL, no cookie printing, and command matching restricted to `aiur-$USER` release nodes.
- **Verification:** Targeted regression tests pass.

### U2. Command/preflight integration for stale manual-smoke leftovers

- **Goal:** Wire the cleanup helpers into startup preflight and `stop`, and expose a cleanup command for stale manual-smoke leftovers.
- **Files:** Modify `packaging/npm/aiur-cli/libexec/aiur-engine.sh`; update tests in `src/test/aiur/regression/shutdown_cleanup_test.exs` and `src/test/scripts_aiurdev_test.exs`.
- **Patterns:** Follow command dispatch structure in `aiur_engine_main` and the dev shim's pure control command list.
- **Test scenarios:** `aiurdev cleanup-stale` forwards through the shim without forcing a stale rebuild; startup calls preflight before launching; `stop` invokes stale cleanup after current-instance cleanup.
- **Verification:** Targeted shim and engine regression tests pass.

---

## Risks & Dependencies

- The cleanup must be conservative when process metadata is incomplete. If root or node cannot be classified as Aiur-owned, report rather than kill.
- Manual TUI verification remains blocked inside this agent workspace by repository policy. The PR should explicitly note that focused tests were used instead.

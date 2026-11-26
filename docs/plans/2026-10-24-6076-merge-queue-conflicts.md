---
title: Preventing merge-queue conflict drops
date: 2026-10-24
artifact_readiness: implementation-ready
---

# Preventing merge-queue conflict drops

## Problem and scope

Issue #6076 reports two approved PRs spending about an hour in GitHub's merge queue before being removed as conflicting when a PR ahead merged. It asks Aiur to check a candidate against `main` plus queued PRs before enqueue, and to let the daemon push a mechanical rebase while retaining approval.

The landing watcher already routes observed conflicts to rebase-only rework (`Aiur.LandingWatch.ConflictRouting`), and the merge queue watchdog already repairs only positively revalidated, clean, approved entries. GitHub's merge group is the authoritative candidate merge: it includes the latest base and changes ahead in the queue. Do not synthesize a local test merge as a substitute because it cannot reproduce GitHub's queue and required-check semantics.

## Requirements

- R1. Never enqueue or re-enqueue an approved candidate if a current, exact-head GitHub observation says it conflicts with the current base/queue; route it to the existing rebase-only conflict path promptly.
- R2. If a mechanically rebased candidate is ever pushed by the daemon, pin the old and new heads, prove its contribution diff is identical using the existing approval-carry classifier, and confirm the push and approval state before preserving approval. Any conflict resolution or uncertain result remains human rework.
- R3. Keep all queue mutations behind existing governed GitHub APIs, LocalHold, identity/head revalidation, journal idempotency, and explicit failure alerts.

## Technical direction

Use `Observer.refresh_queue/2` or a similarly pinned live GraphQL read immediately before queue mutations to observe exact head, base, mergeability and queue position. Gate the normal landing reconciliation enqueue and queue recovery/requeue paths on a fresh result. Fail closed on unavailable or `UNKNOWN` verdict where the code is about to mutate the queue. Reuse `ConflictRouting` for known conflicts and preserve its pause provenance checks.

Do not introduce daemon git push/rebase in the first implementation unless an existing governed write path can meet R2 without adding credentials or weakening review protections. GitHub approval carry explicitly rejects changed contribution diffs; rebases that resolve conflicts change that diff and cannot retain approval under the current documented policy. Treat this as a scope constraint requiring clear evidence rather than promising automatic conflict resolution.

## Implementation units

### U1. Pin queue admission to a fresh candidate verdict

Files: `src/lib/aiur/landing_watch.ex`, `src/lib/aiur/landing_watch/observer.ex`, the concrete enqueue/recovery modules under `src/lib/aiur/landing_watch/`, and focused tests in `src/test/aiur/landing_watch/`.

Follow `MergeQueueWatchdogRecovery`'s revalidation-before-mutation pattern. Add deterministic injected tests for clean exact-head admission, conflicting candidate rejection/routing, stale-head rejection, and read failure (no enqueue). Cover every production enqueue call reached by normal landing and failure recovery.

### U2. Preserve the existing approval boundary for any mechanical rebase

Files: only if a safe, supported daemon rebase path is found in U1; likely `src/lib/aiur/landing_watch/` and its tests. Otherwise record the concrete blocker in the handoff and leave the existing `ConflictRouting` rework path intact.

Tests must prove that a diff-identical rebase can proceed only after all pinned preconditions, and that changed contribution, conflict resolution, changed approval, or failed push never claims approval was preserved.

## Risks and decisions

- GitHub performs the authoritative merge-group test after enqueue; a pre-enqueue observation narrows the race but cannot guarantee the base will not move immediately afterward. Keep the existing post-enqueue conflict watcher as recovery.
- Current approval-carry policy says conflict resolution changes the contribution diff. Therefore the requested second behavior may conflict with repository policy; do not silently broaden carry semantics.
- Additional live GraphQL reads cost GitHub Core budget. Keep the read immediately scoped to actual enqueue attempts and use the shared local-hold path.

## Validation scenarios

- New admission tests fail when the fresh conflict gate is removed, and pass with it.
- Recovery tests verify an exact-head read precedes dequeue/re-enqueue and no mutation occurs on stale or unavailable evidence.
- Focused tests: `mise exec -- mix test test/aiur/landing_watch/...` from `src/`, narrowed to changed and direct caller tests.
- Run the author-side test mutation check in a separate worktree for each new production behavior, as required by `AGENTS.md`.

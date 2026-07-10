---
title: "fix: Honor the configured workspace base branch"
type: fix
status: completed
created: 2026-07-09
---

## Summary

Ensure warm-base refresh, fresh workspace checkout, and init-generated hooks all use `tracker.base_branch`, preserving `main` only as the unset configuration fallback and keeping existing PR-anchored checkout behavior unchanged.

---

## Scope Boundaries

### In scope

- Standard fresh-workspace checkout and generated hook bootstrap/refresh behavior.
- Focused regression coverage for a `v2` base and the default fallback.

### Out of scope

- PR-anchored workspace checkout behavior.
- Changes to an existing user-managed hook file.

---

## Implementation Units

### U1. Use the configured base for fresh checkouts

**Goal:** Materialized standard workspaces branch from the live configured base tip.

**Dependencies:** None.

**Files:**

- Modify: `src/lib/aiur/workspace/checkout.ex`
- Test: `src/test/aiur/workspace_materialize_test.exs`

**Approach:** Fetch and select the same base branch resolved by the warm-base subsystem, retaining the copied warm checkout as the offline fallback. Leave the explicit PR-head path untouched.

**Test scenarios:**

- A stale warm checkout on `v2` materializes `aiur/<id>` at the live `origin/v2` tip after `v2` advances.
- An advance only on `main` does not become the fresh workspace tip.

**Verification:** A materialized workspace’s branch and commit match its configured remote base.

### U2. Export the base branch to generated hooks

**Goal:** Make init-scaffolded hooks clone, fetch, and clean-refresh the configured base without losing the dirty-WIP refusal behavior.

**Dependencies:** U1.

**Files:**

- Modify: `src/lib/aiur/workspace/hooks.ex`
- Modify: `.aiur/examples/hooks.example`
- Test: `src/test/aiur/workspace_and_config_test.exs`
- Test: `src/test/aiur/init/scaffold_test.exs`

**Approach:** Provide a base-branch environment variable alongside the repository URL and consume it in the scaffolded hook shell, with `main` as its local defensive fallback.

**Test scenarios:**

- Generated hooks contain no `origin/main` bootstrap or refresh command and reference the exported base value.
- A `v2` configuration reaches hook execution with `v2` available.
- Existing dirty-worktree refusal remains intact.

**Verification:** New scaffolds and hook execution both target the configured branch while unset configuration retains `main`.

### U3. Characterize non-default warm-base refresh

**Goal:** Prove warm-base cloning and refresh follow `v2`, not unrelated `main` movement.

**Dependencies:** U1.

**Files:**

- Test: `src/test/aiur/repo_base_test.exs`

**Approach:** Add an isolated remote with divergent `main` and `v2` tips, pin the workflow configuration to `v2`, and exercise initial refresh plus subsequent branch movement.

**Test scenarios:**

- First refresh clones `v2`.
- Advancing `v2` refreshes and rebuilds the warm base.
- Advancing only `main` leaves the `v2` warm base unchanged.

**Verification:** The warm base’s checked-out commit and rebuild markers follow only the selected base branch.

---

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| Offline or test remotes lack the configured ref | Preserve the existing copied-HEAD fallback. |
| A resumed PR branch is replaced by the base | Limit the change to standard fresh checkout; retain the PR-head branch path. |

## Sources & References

- Issue: #909
- Related code: `src/lib/aiur/repo_base.ex`, `src/lib/aiur/workspace/checkout.ex`

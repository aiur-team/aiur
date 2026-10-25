---
title: Split GitHub trust modules and tests
type: refactor
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: legacy-requirements
execution: code
---

# GitHub trust file splits

## Goal Capsule

Issue: #3495 (U8-P24-T01). The linked research ticket specifies four
reviewable PRs with no authorization or credential behavior changes.
Current baseline: `47140566f` on the configured integration branch `main`.

## Product Contract

Keep public functions, cache keys, diagnostics, token precedence, timeline
ordering and queue-marker rules unchanged. Preserve every existing test and
assertion. Each resulting file must fit the 500-line gate; aim for 200 lines
and explain cohesive larger test groups. No saving is claimed.

The prerequisite U0, U5 and MP-E1-C1-T01..T05 issues are closed. Current
CODEOWNERS already fits at 499 lines following the U5 extraction; preserve
that implementation rather than applying the stale proposed split.

## Implementation Units

1. Split the five oversized test files only. Group issues tests by states,
   candidates, IDs, blockers, normalization and conditional reads. Group
   config tests by token resolution, keyring, repository and App tokens.
   Group preflight tests by diagnostics, wait-out and fail-closed behavior.
   Group dispatch tests by appliers, timeline, cache and alerts. Split state
   transitions further because the current describe alone exceeds 500 lines.
2. Extract `src/lib/aiur/github/issues.ex` into raw-issue revalidation,
   label pages, ID-list reads and normalization, preserving public delegates.
3. Extract `src/lib/aiur/github/config.ex` token and keyring responsibilities.
   Keep timeout and process-tree termination together and retain cache keys.
4. Extract auth diagnostics and dispatch timeline reads/decisions. Recount
   `src/lib/aiur/codeowners.ex` and keep it unchanged if still within budget.

PRs use `Refs #3495` until the final acceptance criteria are satisfied.
Each PR requires security review. Continue with the next family after the
previous PR merges; do not close the ticket after the test-only PR.

## Planning Contract

Keep setup and cleanup identical. Reuse narrowly scoped test fixtures in
family-local support modules when multiple test modules need them; keep
support files under 500 lines. Avoid introducing a shared global fixture
or altering the repository-wide test harness.

All new test files remain within `src/test/aiur/github/**/*_test.exs`.
Retain describe names and test names. Compare the original test-body
multiset against the split files and compare the executed test counts.
No new regression tests are needed for a pure move; there is no production
hunk to revert in PR 1.

## Verification Contract

Run all moved test families with `mix test --max-cases 4`, plus the affected
test selector. Compile with warnings as errors, format, run `mix lint`,
the bare-receive check and the committed-head structural gate.

Global token caches, environment variables and alert subscriptions make
fixture preservation essential. Test modules must retain their synchronous
execution settings. Unused aliases/helpers introduced by splitting must be
removed or placed in the narrow fixture module without editing assertions.

Source PRs additionally run direct-caller tests and the trust failure matrix.
Preserve incomplete-timeline invalidation ordering and fail-closed outcomes.
Record before/after source, test and documentation line counts per PR.

Manual reset harnesses are prohibited in agent workspaces; PR 1 changes no
user-facing behavior. CI remains the authoritative required-check gate.

## Definition of Done

Every original oversized path and every new file fits 500 lines, all original tests still run, and each PR passes its required checks and security review.
The final PR recounts tracked text, verifies E1 hooks and closes #3495.
PR 1 alone does not complete the ticket.

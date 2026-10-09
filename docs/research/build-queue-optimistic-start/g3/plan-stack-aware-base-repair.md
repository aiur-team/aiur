---
title: "feat: Let a dependent PR target its open blocker's branch - Plan"
date: 2026-10-09
type: feat
area: G3
ticket: BQ-G3-1
epic: aiur-team/aiur#3755
origin: docs/research/build-queue-optimistic-start/g3/brainstorm.md
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# feat: Let a dependent PR target its open blocker's branch - Plan

## Goal Capsule

- Objective: the CI poller's base repair accepts a stacked base. A dependent PR may target the head branch of an open, unmerged PR of one of its `blocked_by` blockers. Every other wrong base is still repaired to `tracker.base_branch`. After the blocker merges, the stack base reverts to the integration branch.
- Covers: brainstorm R1 and R2, plus KD1.
- Code baseline: `origin/main` at `0e5b8d0de`. Paths are repo-relative.
- Product Contract unchanged.

---

## Problem Frame

`Aiur.Events.GithubCiPoller` reads one expected base, `Config.base_branch(opts)` (`src/lib/aiur/events/github_ci_poller.ex`, `expected_base_branch/1`). It calls `ensure_pull_request_base/5` on all three poll paths (single, batched, and re-read). `Aiur.GitHub.PullRequests.ensure_base_branch/3` (`src/lib/aiur/github/pull_requests.ex`) PATCHes any other base back to that one, journals a base repair, and invalidates CI for the head. G2's optimistic worker opens its PR with `--base <blocker head branch>`. That base is flipped to `main` within one poll, so the PR diff absorbs the blocker's code. Two texts restate the single-base rule and would contradict G2: the agent prompt (`src/lib/aiur/prompt_builder.ex`, `integration_branch_restatement/0`) and the Executor review precondition (`.claude/skills/aiur-run/references/executor.md`, "Pull-request review loop", first bullet).

## Requirements

- R1. A dependent PR may target the head branch of an open, unmerged PR of one of its `blocked_by` blockers, and that base is left alone.
- R2. Once that blocker PR is merged or closed, the expected base for the dependent is `tracker.base_branch` again, and the existing repair applies. GitHub auto-retargets when the head branch is deleted. This covers repos that keep merged branches.
- R1a. If Aiur cannot resolve the blocker facts (no cached delivery, read error), it repairs to the integration branch, as today. A wrong-but-safe `main` base costs only review clarity. The G3-3 gate still holds the merge.

## Key Technical Decisions

- KTD1. Introduce `Aiur.Stacking.StackBase`. It is a pure function from (PR base ref, ticket id, list of blocker facts, integration branch) to `{:ok, :integration}`, `{:ok, {:stacked, blocker_id}}`, or `{:repair, integration_branch}`. The poller asks it, not `Config.base_branch/1` alone. A pure module can be tested without HTTP. G3-2 and G3-3 reuse the same blocker facts.
- KTD2. Blocker facts come from data the daemon already holds, with no new GitHub reads on the poll path. The facts are the ticket's `blocked_by` list (`Aiur.Issue.blocked_by`, hydrated by `Aiur.GitHub.Issues.hydrate_blocked_by/1` and cached under `:issue_blocked_by`) and each blocker's delivered PR (`Aiur.GitHub.TicketPullRequest.read/1`). Extend `TicketPullRequest.parse/2` to also return `head_ref`, `head_sha`, `base_ref`, and `merge_commit_sha` from the delivered body. These fields are present in the webhook `pull_request` payload. G3-2 and G3-3 consume the extended map (the "blocker PR facts" interface).
- KTD3. Allow a stacked base only for a direct blocker. Chains (A blocks B blocks C) still work, because each PR stacks on its own direct parent.
- KTD4. Keep a single journal and invalidation path. A stacked base yields `{:ok, :unchanged}` exactly like an integration base. The CI-invalidation semantics in `enforce_base_repair_invalidation/6` stay untouched.

## Implementation Units

### U1. Blocker PR facts

- Goal: `TicketPullRequest.read/1` returns `head_ref`, `head_sha`, `base_ref`, and `merge_commit_sha` alongside today's `state`, `merged?`, `number`, and `version`.
- Requirements: R1, R2.
- Files: `src/lib/aiur/github/ticket_pull_request.ex`, `src/lib/aiur/tracker.ex` (result typespec), `src/test/aiur/github/tracker_ticket_pull_request_test.exs`.
- Approach: read the extra keys from the stored body, and use `nil` when one is absent. Existing callers (`Aiur.BuildQueue.PRObserver`) match on the old keys only and stay unaffected.
- Test scenarios: an open delivered PR returns its `head_ref` and `head_sha`. A merged PR returns a non-nil `merge_commit_sha`. A body missing `head` still parses, with `nil` fields. An expired delivery still returns `{:ok, nil}`.
- Verification: the PRObserver tests still pass unchanged.

### U2. `Aiur.Stacking.StackBase`

- Goal: one decision function for a PR's expected base.
- Requirements: R1, R2, R1a. KTD1, KTD3.
- Dependencies: U1.
- Files: `src/lib/aiur/stacking/stack_base.ex` (new), `src/test/aiur/stacking/stack_base_test.exs` (new).
- Approach: inputs are `current_base`, `integration_branch`, and `blockers` (each `%{id, pr: facts | nil}`). Return `{:ok, {:stacked, id}}` only when `current_base == facts.head_ref`, `facts.state == :open`, and `facts.merged? == false`. Otherwise return integration (unchanged when `current_base == integration_branch`, `{:repair, integration_branch}` when not).
- Test scenarios: the base equals an open blocker's head ref, so the result is stacked. The base equals a merged blocker's head ref, so the result is repair. The base equals a closed-unmerged blocker's ref, so the result is repair. The base equals a non-blocker ticket's branch, so the result is repair. Blocker facts are `nil`, so the result is repair. The base is the integration branch, so the result is unchanged.
- Verification: a mutation that drops the `merged?` check fails the merged-blocker scenario.

### U3. Poller uses StackBase

- Goal: all three `ensure_pull_request_base` call sites in `src/lib/aiur/events/github_ci_poller.ex` skip the PATCH for a stacked base.
- Requirements: R1, R2. KTD2, KTD4.
- Dependencies: U2.
- Files: `src/lib/aiur/events/github_ci_poller.ex`, `src/test/aiur/events/github_ci_poller_test.exs`.
- Approach: before calling `Client.ensure_pull_request_base/3`, resolve the target ticket's blockers from the in-memory issue (the poll target carries the issue) and their facts via U1. When StackBase says stacked, return `{:ok, :unchanged}` without a request, and log `pull request base stacked: pr=N blocker=B` at debug. Otherwise call the existing path unchanged.
- Test scenarios: (integration, with a `request_fun` stub) a PR based on an open blocker branch makes no PATCH and gets a normal CI verdict. The same PR after the blocker's delivery flips to merged makes exactly one PATCH to `main` plus the journal entry. A PR based on an unrelated branch makes a PATCH, as today. Blocker hydration missing makes a PATCH (fail toward integration).
- Verification: the existing base-repair tests pass unchanged.

### U4. Agent prompt and Executor review text

- Goal: the restated rule names the stack exception, so agents and the Executor follow the code.
- Requirements: R1.
- Files: `src/lib/aiur/prompt_builder.ex` (`integration_branch_restatement/0`), `src/test/aiur/prompt_builder_test.exs`, `.claude/skills/aiur-run/references/executor.md` ("Pull-request review loop" first bullet), `website/docs-app/concepts/ticket-lifecycle.md` (Build queue section, one paragraph "Stacked pull requests").
- Approach: the prompt says the base is `tracker.base_branch`, except that while a `blocked_by` blocker's PR is open, the PR may target that blocker's head branch, and Aiur moves it back to the integration branch after the blocker merges. The Executor bullet says the base is either the integration branch or a stacked base that Aiur reports. A stacked PR is reviewable but not mergeable (see G3-3).
- Test scenarios: the prompt test asserts that the restatement contains both the integration branch and the stacked-base exception.
- Verification: the docs paragraph stays within the 360-character guard (`gui-docs.spec.ts`).

---

## Verification Contract

- `mix test` passes for the touched test files. The `pull_requests_test.exs` base-repair suite passes unchanged.
- A manual check against a live two-ticket stack: the dependent PR keeps `baseRefName = aiur/<blocker>-...` across three poll cycles, and after the blocker merges, it reads `main`.

## Definition of Done

- U1 through U4 are merged, with tests that fail when the stacked check is removed.
- The docs and the Executor reference ship in the same PR.

## Rollout

- There is no flag. The change only widens acceptance for a base that names an open direct blocker's head branch, which no non-stacked PR has. To roll back, revert. The poller then repairs stacked PRs to `main`, which is today's behavior.

## Risks

- Stale delivered PR facts (webhook missed) make the blocker look open after it merged. The stacked base then persists until GitHub's own auto-retarget, which this repo gets from `delete_branch_on_merge: true`. The G3-3 gate refuses merge either way, because the base is not the integration branch.
- A blocker head branch shared by two tickets is not a pattern here. Branches are `aiur/<id>-<slug>`.

## Seams

- G2 opens the dependent PR against the blocker head branch. This plan is what makes that base durable.
- G3-2 and G3-3 consume the U1 fields (the blocker PR facts interface).

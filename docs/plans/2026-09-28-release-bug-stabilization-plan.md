---
title: Aiur release bug stabilization
type: fix
date: 2026-09-28
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
---

# Aiur release bug stabilization

## Goal Capsule

Close the confirmed Aiur regressions that can strand an agent, bypass a required worker guard, or give a consumer worker the wrong test contract. Merge reviewed fixes, then prove the latest `main` through the real `aiurdev` TUI with multiple agents before publishing packages. Existing issue contracts remain authoritative for each bug. This plan coordinates that work; it does not replace those tickets.

## Product Contract — `/ce-brainstorm` synthesis

### Problem and desired outcome

Khala's current Aiur run reproduced tickets that do not dispatch, formal review feedback that does not reach rework, and mandatory worker checks that depend on shell composition or a mismatched installed CLI. A separate consumer instruction bug tells TypeScript workers to run Elixir commands. Operators need a release in which these paths work under ordinary conditions, with failures visible and recoverable.

### Scope and decisions

- R1. A dispatchable `agent:todo` ticket must enter the tracked set and dispatch or show a truthful, actionable decline without repeated `resume` calls. Cover creation with the label, later labeling, and recovery from an orphaned claim. [#2818](https://github.com/aiur-team/aiur/issues/2818)
- R2. A formal `CHANGES_REQUESTED` review on an `agent:human-review` ticket must move it to rework or leave one durable refusal with a reason. Its body must remain available after a cold restart. [#2817](https://github.com/aiur-team/aiur/issues/2817), [#2794](https://github.com/aiur-team/aiur/issues/2794)
- R3. Workers must run the mandatory deletion guard from the daemon's own build. If a shell pipeline masks its refusal and pushes the branch, a trusted required check must still block merging excessive deletions. [#2803](https://github.com/aiur-team/aiur/issues/2803), [#2802](https://github.com/aiur-team/aiur/issues/2802)
- R4. Consumer workers must select focused tests from their own repository. Aiur workers retain their Aiur-specific commands and the destructive `aiurdev --test` workspace prohibition. [#2824](https://github.com/aiur-team/aiur/issues/2824)
- R5. A ticket without a complexity label must pass the same backend availability check as labeled tickets. [#2814](https://github.com/aiur-team/aiur/issues/2814)
- R6. Provider rate-limit recovery must not generate routine false `needs_attention` alerts or serialize each ticket behind an avoidable refusal. [#2811](https://github.com/aiur-team/aiur/issues/2811)

The user has authorized fixing reported bugs before release, but has not chosen which open backlog items are a hard release gate. This plan treats R1–R4 as the first gate because the reports show current workflow failure or a bypassed mandatory safeguard. R5–R6 are next if reproduced on the release candidate or if their existing ticket owners finish before the release cut. This is a scheduling assumption, not a claim that other open bugs are fixed.

### Acceptance examples

- AE1. A newly created labeled ticket appears in status, dispatches once when a slot is free, and needs no repeated operator resume; a denied dispatch gives a stable reason.
- AE2. A body-only request-changes review wakes rework, and the worker can recover the review body after its queued event is gone.
- AE3. A worker invokes the daemon-build guard despite an older global `aiur`; if `guard | tail` masks refusal and permits a push, a trusted required check fails on that PR and ordinary actors cannot merge it.
- AE4. A Khala/TypeScript worker runs a repository-specific focused test; an Aiur worker runs the scoped ExUnit workflow; both understand that only the destructive sandbox command is prohibited in ticket workspaces.
- AE5. Unlabeled tickets wait for an exhausted backend, and normal provider recovery raises no false operator warning.

### Explicitly outside this batch

The stopped-daemon detection work in [#2764](https://github.com/aiur-team/aiur/issues/2764) needs an independent monitor and product decision; do not claim the release resolves it. Khala's repeated `EPERM` Executor access incident is tracked in [#2825](https://github.com/aiur-team/aiur/issues/2825). A draft skill circuit-breaker exists in the shared dirty checkout, but the owner of model wake deduplication is unverified. The issue requires locating that owner before claiming an integration fix. Do not mistake a sandbox denial for a stopped daemon or an empty queue.

## Planning Contract — `/ce-plan` enrichment

### Technical decisions and dependencies

Each existing issue should be implemented in its own isolated worktree and PR. R1 and R2 touch dispatch/rework orchestration and should not be merged without an integration rerun against their combined head. R3 has three stages: bind worker PATH to the daemon build (#2802), catch masked exits in ordinary PR CI (#2835), then require a trusted-base status whose code the PR cannot change (#2803). The first two do not close #2803. R4 is independent and can run in parallel. R5 uses the established `model_fallback_waiting` path. R6 follows ownership and wake observations from its ticket rather than introducing a new alert state.

### Work units

| Unit | Ticket and outcome | Dependency | Verification |
| --- | --- | --- | --- |
| U1 | [#2818](https://github.com/aiur-team/aiur/issues/2818): diagnose created-with-label, later-label, and orphaned-claim cases; repair each proven boundary | None | Deterministic event/claim tests, then real `aiurdev` todo dispatch without resume loops. The first PR fixes the create-with-label timeline-cache subtype only; #390 and the broader resume loop remain unproven, so keep the issue open pending latest-main judgment. |
| U2 | [#2817](https://github.com/aiur-team/aiur/issues/2817) and [#2794](https://github.com/aiur-team/aiur/issues/2794): accept/retry formal review, persist refusal, cold-rederive body | U1 integration review | Formal body-only review test, restart/rework test, TUI-visible worker feedback |
| U3 | [#2802](https://github.com/aiur-team/aiur/issues/2802): bind worker CLI to the daemon build | None | Worker PATH from a stale global install resolves the daemon command and preserves unrelated tools |
| U4 | [#2803](https://github.com/aiur-team/aiur/issues/2803): catch masked guard exits in PR CI, then add a trusted required merge gate | U3 | Piped refusal can push but fails the trusted check; stale branches with only base-side additions pass; a non-bypass actor cannot merge a blocked PR |
| U5 | [#2824](https://github.com/aiur-team/aiur/issues/2824): repository-aware worker validation guidance | None | Installed non-Elixir fixture has no unconditional `mix` gate; Aiur fixture retains scoped ExUnit guidance |
| U6 | [#2814](https://github.com/aiur-team/aiur/issues/2814): check unlabeled fallback backend | None | Fixed-time exhausted/available backend cases |
| U7 | [#2811](https://github.com/aiur-team/aiur/issues/2811): remove normal recovery refusal/false alert | U1 ownership context | Multi-ticket limit-clear test, real alert ledger and dispatch timing census |

### Merge and release order

1. Merge reviewed U5 and U3 early; U1/U2 can progress in parallel but require a combined dispatch/review acceptance pass. Merge U4 after U3. Add U6/U7 as their issue evidence and implementation pass.
2. For each PR, confirm the new tests fail when the production hunk is removed in an isolated worktree, then pass restored; record exact commands in the PR body. Review current head, address findings, and wait for required CI before merge.
3. Pull latest `main` after all selected fixes merge. Launch the real foreground `scripts/aiurdev --test` TUI from the Executor checkout with local memory/nonshared fixtures, open chat panes, send user-path messages, and run at least two agents through dispatch, tool use, review/rework and completion where feasible. One agent must work in a TypeScript consumer workspace and select/run that repository's affected test command, proving #2824 in real behavior. Capture rendered pane evidence and exact build identity. A log or HTTP-only check does not satisfy this gate.
4. Registry preflight found `aiur-cli` and all three platform packages already published at `0.0.5`, matching the current source version. After fixes merge, bump the stable version to `0.0.6` in `src/mix.exs` and run `packaging/scripts/stamp-versions.mjs`; do not bump on a planning or bug branch. Run the release dry run, then stable publish under the repository's release procedure. Verify each package's `0.0.6` registry entry and package-manager install path before resuming refactor research.

## Risks and verification contract

- Existing `main` and the shared root checkout differ; do not patch or restart the shared live release. Use issue worktrees and merge against current `main`.
- GitHub issue titles and status may change while agents work; recheck open PRs before claiming a ticket or publishing a duplicate.
- For GitHub poll/credential changes, read and update `website/docs-app/apis/github.md`; for changed CLI or operator behavior, update the owning docs page in the same PR.
- A green unit suite is necessary but insufficient for this release. Verify combined behavior with the real TUI and the exact merged `main` commit.
- Do not call an unverified open backlog ticket fixed, and do not claim an npm release until all intended package names and versions are visible in their registries.

## Definition of Done

U1–U5 fixes are merged with current-head review, mutation-sensitive tests, and green required CI; U4's trusted status is pinned in the Aiur and Khala target rulesets and shown to block a real over-threshold PR for non-bypass actors. U6/U7 are either merged or explicitly judged against latest-main evidence before release. The real multi-agent TUI test passes on latest `main`, publication succeeds for all intended packages, and install checks resolve those published versions. Outstanding unrelated bugs remain accurately tracked rather than silently folded into a release claim.

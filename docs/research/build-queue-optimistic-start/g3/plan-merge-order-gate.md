---
title: "feat: Refuse to merge a dependent PR before its blocker - Plan"
date: 2026-10-09
type: feat
area: G3
ticket: BQ-G3-3
epic: aiur-team/aiur#3755
origin: docs/research/build-queue-optimistic-start/g3/brainstorm.md
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# feat: Refuse to merge a dependent PR before its blocker - Plan

## Goal Capsule

- Objective: replace the reviewer-brief judgment "the PR is not stacked on an unmerged sibling" with a deterministic check that fails closed. Every Executor merge runs it before `gh pr merge`. It lets a dependent PR merge only when its base is the integration branch and every `blocked_by` blocker has landed and is contained in the PR head. A daemon attention catches merges that skipped the check.
- Covers: brainstorm R6, R7, R8, R9, R10 (verify half). KD4, KD5, KD6, KD7.
- Code baseline: `origin/main` at `0e5b8d0de`. Paths are repo-relative.
- Product Contract unchanged.

---

## Problem Frame

The daemon never merges (`src/lib/aiur/orchestrator/ci_lifecycle.ex`, merge-queue comment: "The daemon never arms auto-merge (the human-only merge gate in #1841)"). The Executor merges with `gh pr merge --squash --admin`. The live `human-only-merge-gate` ruleset lists its-everdred as a `pull_request` bypass actor, so a required status check does not hold that path. The ruleset also covers only `main` and `develop`. A dependent PR whose base is the blocker branch can be merged into the blocker branch with no rule applied, which silently grows the blocker PR. Today the only guard is reviewer judgment.

## Requirements

- R6. Refuse unless all of these hold: P's base is the integration branch; for each `blocked_by` blocker B of P's ticket, B is closed `completed`, or B has a merged PR; and for each B with a merged PR, B's merge commit is an ancestor of P's head. Anything else refuses, with one line per reason. That includes unknown state, read errors, B closed `not_planned` or `duplicate`, and B's PR closed unmerged.
- R7. The check is a script in the aiur-run skill, next to `diagnose-pr-merge-gate.sh`. It works without the daemon and uses the operator's `gh` (with `GITHUB_TOKEN`/`GH_TOKEN` unset, as that script does). Exit 0 means pass, exit 2 means refuse, exit 3 means it cannot decide (also a refusal).
- R8. The script has no override flag. Removing the `blocked_by` edge is the documented escape.
- R9. When `ticket.<T>.pr.merged` arrives while T has a blocker that R6 would not accept, the daemon raises a critical alert naming T, the PR, and the blockers.
- R10 (verify). When the PR's approval was dismissed and every commit after the approved head is an Aiur restack commit (BQ-G3-2 trailers) whose tree the script recomputes byte-for-byte, the script prints `RESTACK-ONLY <approved sha>..<head>` so the merge helper can re-approve without a new review.

## Key Technical Decisions

- KTD1. Ancestry is checked with the REST compare endpoint (`repos/{o}/{r}/compare/{merge_sha}...{head}`): status `ahead` or `identical` means contained. This needs no local clone and costs one request per blocker. A local `git merge-base --is-ancestor` is used instead when the caller passes `--repo-dir`, because the Executor's helper already has a fetched clone.
- KTD2. The ticket comes from the PR's head ref `aiur/<id>[-slug]`. That is the same canonical parse the daemon uses (`Aiur.TicketBranch`, used by `src/lib/aiur/recent_merge.ex`). A PR whose head is not a ticket branch has no blockers and passes on the base rule alone.
- KTD3. Blockers come from `repos/{o}/{r}/issues/{id}/dependencies/blocked_by` (the native list the daemon hydrates). A blocker's merged PR is found from the blocker ticket's branch via `scripts/resolve-ticket-branch` semantics, falling back to `gh pr list --state merged --search "head:aiur/<id>"`. More than one merged PR for one blocker means refuse (ambiguous).
- KTD4. The detective alert reuses the existing blocked_by cache and the `pr.merged` route in `Aiur.Orchestrator.EventTopics`. It is an `emit_alert`-style Executor alert with `severity: critical`. It does not undo anything.
- KTD5. No required status check and no daemon-published commit status (see brainstorm KD4). Recorded so the next reader does not reopen the question: `--admin` skips it, and it would block every non-ticket PR.
- KTD6. Script plus fixture-`gh` tests, following the existing `scripts/test-fixtures/human-only-merge-ruleset/gh` pattern and `.claude/skills/aiur-run/scripts/tests/*_test.sh`.

## Implementation Units

### U1. `check-stack-order.sh`

- Goal: the deterministic gate.
- Requirements: R6, R7, R8. KTD1, KTD2, KTD3.
- Files: `.claude/skills/aiur-run/scripts/check-stack-order.sh` (new), `.claude/skills/aiur-run/scripts/tests/check-stack-order_test.sh` (new), `scripts/test-fixtures/stack-order/gh` (new fake `gh` answering from JSON fixtures).
- Approach: usage `check-stack-order.sh <pr> [owner/repo] [--base <integration branch>] [--repo-dir <clone>]`. The integration branch defaults to the repo default branch from `gh repo view`. Print `PASS` or `REFUSE <reason>` lines. Any `gh` failure prints `UNDECIDED <step>` and exits 3. `set -euo pipefail`. Never treat an empty answer as "no blockers": distinguish an empty JSON array from a failed read.
- Test scenarios: no blockers and base main gives exit 0. Base is the blocker branch gives exit 2 with `REFUSE base`. The blocker issue is open gives exit 2. The blocker is merged but its merge commit is not an ancestor (compare `diverged` or `behind`) gives exit 2 with `REFUSE restack-needed #B`. The blocker is merged and contained gives exit 0. The blocker is closed `completed` with no PR gives exit 0. The blocker is closed `not_planned` gives exit 2 with a hint to remove the edge. The blocker's PR is closed unmerged gives exit 2. The blocked_by read returns HTTP 500 gives exit 3. Two merged PRs for one blocker gives exit 2 (ambiguous). Head ref is not a ticket branch and base is main gives exit 0.
- Verification: each scenario is a fixture case. The test fails if the ancestry check is removed.

### U2. Restack-only re-approval check

- Goal: recognize a dismissed approval whose only delta is BQ-G3-2 restack commits.
- Requirements: R10. Depends on BQ-G3-2 U1 (trailer format).
- Files: `.claude/skills/aiur-run/scripts/check-stack-order.sh` (`--approved <sha>` option), same test file.
- Approach: with `--approved <sha>` and `--repo-dir`, list the commits in `<sha>..<head>`. Each must carry an `Aiur-Restack:` trailer. Recompute each one's tree from its parents and its trailer `blocker-head` (merge-tree with `merge-base(first parent, blocker-head)`), and compare it to the commit's tree. Print `RESTACK-ONLY` only when all match. Otherwise print nothing extra. This output never turns a refusal into a pass.
- Test scenarios: one honest restack commit gives RESTACK-ONLY. A restack commit with an edited tree gives no RESTACK-ONLY. A restack plus one ordinary commit gives no RESTACK-ONLY. A missing trailer gives no RESTACK-ONLY.

### U3. Executor merge path uses the check

- Goal: the gate runs on every Executor merge.
- Requirements: R7, R8.
- Dependencies: U1.
- Files: `.claude/skills/aiur-run/references/executor.md` ("Pull-request review loop" and "Merge mechanics": run `check-stack-order.sh` before any `gh pr merge`, refuse on a non-zero exit, and on `RESTACK-ONLY` re-approve with a one-line body naming the recomputed range), `.claude/skills/aiur-run/SKILL.md` (merge policy line), `website/docs-app/concepts/build-orders.md` ("Merge order" paragraph).
- Approach: the operator-local helper `merge-if-safe.sh` (outside the repo, in the Executor scratch dir) gains one call to the script after its draft and CI checks. That edit is an Executor rollout step, recorded in the PR body, not repo code.
- Test expectation: none for the prose. The docs prose guard applies.
- Verification: the reviewer brief's rule 5(d) is replaced by "run check-stack-order.sh".

### U4. Out-of-order merge alert

- Goal: a detective control for merges that skipped U1.
- Requirements: R9. KTD4.
- Files: `src/lib/aiur/orchestrator/event_topics.ex` (pr_merged route), `src/lib/aiur/stacking/merge_order.ex` (new, pure: issue plus blocker facts gives `:ok` or `{:violation, blockers}`), `src/lib/aiur/alerts.ex` (alert name `merge.out-of-order`), tests `src/test/aiur/stacking/merge_order_test.exs` (new) and `src/test/aiur/orchestrator_firehose_test.exs`.
- Approach: on `ticket.<T>.pr.merged`, read T's cached `blocked_by` and each blocker's facts (BQ-G3-1 U1). Raise the alert once per merge, deduped by PR number, when any blocker is open or merged without containment. For the containment test, use one compare request per merged blocker (blocker merge commit against the merged PR's head sha from the event payload). This is the only GitHub read, and it runs only on a merge of a ticket that has blockers. When facts are missing, raise at `warning` with "could not verify", never silently pass.
- Test scenarios: T merges with an open blocker, so one critical alert names both. T merges after its blocker was merged and contained, so no alert. Duplicate merge events give one alert. Missing blocker facts give a warning alert. Non-ticket PRs give no alert.
- Verification: the alert appears in `aiur alerts` output in the firehose test harness.

---

## Verification Contract

- The fixture tests in `.claude/skills/aiur-run/scripts/tests/check-stack-order_test.sh` pass. The workflow-security job runs the skill script tests (the implementer confirms the job's glob picks up the new test, as the existing `executor-cli-check_test.sh` is).
- The Elixir tests for U4 pass.
- Live dry run: run the script against a merged historical PR (expect PASS) and against an open stacked PR from a G2 pilot (expect `REFUSE base`).

## Definition of Done

- U1 through U4 are merged, `executor.md` names the script on the merge path, and the Executor's `merge-if-safe.sh` calls it (rollout step).

## Rollout

- The script is always on once the Executor's helper calls it. There is no config key, because the gate is in the Executor path, not the daemon. U4 is always on. It reads only cached data.

## Risks

- A GitHub UI merge by the bypass actor skips U1. U4 reports it after the fact. Accepted (brainstorm KD6).
- The compare endpoint is rate-limited like other REST calls. The cost is one call per blocker per merge, which is negligible.
- A false refusal on a blocker closed `completed` by hand while its PR stayed open: the script refuses, because "has a PR that is not merged" plus "closed completed" is ambiguous. The fix is to merge or close the PR. This is fail closed by design.

## Seams

- BQ-G3-1 U1 supplies the blocker PR facts for U4.
- BQ-G3-2 U1 defines the restack trailer that U2 verifies.
- G1: the gate is independent of the start trigger. Every trigger relies on it.
- G4: a blocker that is `not_planned` or closed unmerged is refused here. G4 decides what the dependent does next.

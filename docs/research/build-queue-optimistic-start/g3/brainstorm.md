---
title: Build queue optimistic start, G3 stacking safety - Plan
date: 2026-10-09
type: feat
area: G3
epic: aiur-team/aiur#3755
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
---

# Build queue optimistic start, G3 stacking safety - Plan

## Goal Capsule

- Objective: when a dependent ticket starts before its blocker merges (G1 `pr_opened` and similar triggers, G2 optimistic worker), the dependent's code must land on `main` only after the blocker, and it must land without dragging the blocker's pre-squash commits back into review or into conflicts.
- Product authority: Kevin's epic #3755 intent ("keep agents moving tickets as quickly as possible", "auto-subscribed to when commits are pushed in their parent dependency"). This run was unattended; every decision below was made by the area agent and is recorded with its reason.
- Open blockers: none for the plan. Two operator questions are listed at the end; each has a recommended answer that the plan already assumes.

## Product Contract

### Problem

Today an optimistic dependent is unsafe in three ways. All three were verified against `origin/main` at `0e5b8d0de`.

1. The daemon defeats GitHub-native stacking. The CI poller calls `ensure_pull_request_base` on every polled PR (`src/lib/aiur/events/github_ci_poller.ex:136`, `:192`, `:258`). `Aiur.GitHub.PullRequests.ensure_base_branch/3` (`src/lib/aiur/github/pull_requests.ex:735-789`) PATCHes any base that is not `tracker.base_branch` back to it. A dependent PR that targets its blocker's branch, as G2 asks, is flipped to `main` on the next poll. Its diff then contains the blocker's code, so the Executor reviews the blocker twice. The agent prompt says the same thing: `src/lib/aiur/prompt_builder.ex:106` tells agents to "create or retarget pull requests with `--base "<base_branch>"`". `.claude/skills/aiur-run/references/executor.md:375` makes "baseRefName is the configured integration branch" a precondition for review.
2. A squash merge breaks the dependent's branch. This repo squash-merges with an empty body. The Executor helper runs `gh pr merge --squash --body ""`. The repo setting is `delete_branch_on_merge: true`. After the blocker lands, `main` holds one new squash commit. The dependent still holds the blocker's original commits. GitHub documents the result: "later pull requests can include commits that were already squashed into the base branch. This can make merge conflicts more likely and can force you to resolve the same conflicts more than once" ([About pull request merges](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/about-pull-request-merges)). The toy reproduction in the Appendix shows this. A plain `git merge main` into the dependent conflicts wherever the dependent edited lines the blocker introduced.
3. No mechanism keeps the dependent from merging first. The only guard is a line in the Executor's reviewer brief: "(d) the PR is not stacked on an unmerged sibling". It is a reviewer judgment, and the brief lives outside the repo. The daemon never merges (`src/lib/aiur/orchestrator/ci_lifecycle.ex:750-755`, human-only merge gate #1841). Every merge goes through the Executor's `gh pr merge --squash --admin`. The live ruleset `human-only-merge-gate` lists `its-everdred` (actor 1020682) as a `pull_request` bypass actor. A required status check therefore cannot stop that path. The ruleset also covers only `refs/heads/main` and `refs/heads/develop`. Merging a stacked PR whose base is the blocker branch goes into the blocker branch with no review rule at all. The blocker's PR would then silently carry the dependent's code.

### GitHub behavior this design relies on (cited and checked)

- On merge, the head branch is deleted. "If you delete a head branch after its pull request has been merged, GitHub checks for any open pull requests in the same repository that specify the deleted branch as their base branch. GitHub automatically updates any such pull requests, changing their base branch to the merged pull request's base branch." ([Merging a pull request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/merging-a-pull-request)). This repo has `delete_branch_on_merge: true` (checked with `gh api repos/aiur-team/aiur`). A stacked dependent is therefore retargeted to `main` without our help. Repos that keep head branches get no retarget, so Aiur must handle that case itself.
- A retarget changes only the base. The commits stay. "When you change the base branch of your pull request, some commits may be removed from the timeline. Review comments may also become outdated." ([Changing the base branch](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/changing-the-base-branch-of-a-pull-request)). After the retarget, the dependent's diff against `main` again shows the blocker's pre-squash changes until it is restacked.
- `refs/pull/<n>/head` survives branch deletion. Checked: PR #3742's branch `aiur/3330-mp-r1-c9-t06` is gone, and `git ls-remote origin refs/pull/3742/head` still returns its final `headRefOid` `3b29c92`. This gives a durable oracle for "the blocker's final pre-squash head".
- The `pull_request` bypass skips required checks. `merge-if-safe.sh` uses `--admin` on purpose so it can merge while required checks are still pending. A gate that GitHub alone enforces would be skipped on exactly the path that merges almost every PR.

### Actors

- Executor: reviews and merges, always as its-everdred through the merge helper.
- Dependent agent: a worker on the optimistic ticket (G2).
- Orchestrator: polls PRs, receives `ticket.<n>.pr.merged` (`src/lib/aiur/events/github_firehose.ex:392-423`), and wakes blockees mid-turn on a blocker merge (`src/lib/aiur/orchestrator/auto_subscriptions.ex:350-365`).

### Requirements

- R1. A dependent PR may target the head branch of an open, unmerged blocker PR, and Aiur leaves that base alone. Aiur takes the blocker from the ticket's native `blocked_by` edges. Every other non-integration base is still repaired, as today.
- R2. When a blocker's PR has merged, the expected base for every dependent is the integration branch again. The existing repair covers repos where GitHub did not auto-retarget.
- R3. After a blocker squash-merges, Aiur restacks each dependent so that (a) the PR diff against `main` contains only the dependent's own change, (b) the blocker's merge commit is an ancestor of the dependent head, and (c) no push rewrites published history in the common case.
- R4. When no dependent agent run is live, the orchestrator performs the restack. When a run is live, the agent performs it, on the `ticket.<blocker>.pr.merged` wake it already receives. Either path names the blocker PR and its final head.
- R5. If the restack conflicts, the ticket goes to rework with a machine-readable reason (`restack_conflict`), the blocker PR number, and the conflicted paths. The orchestrator never pushes a conflicted or partial result.
- R6. A merge-order gate refuses to merge PR P for ticket T unless all of these hold: P's base is the integration branch; for every `blocked_by` blocker B of T, B's issue is closed `completed`, or B has a merged PR; and for every blocker with a merged PR, that PR's merge commit is an ancestor of P's head. Any other state refuses. That includes an unknown state, a read error, B closed `not_planned`, and B's PR closed without merge.
- R7. The gate is the step every Executor merge path runs before `gh pr merge`. It ships in the repo next to `diagnose-pr-merge-gate.sh`, works without the daemon, and uses the operator's `gh` identity.
- R8. To merge out of order, remove the `blocked_by` edge. That leaves a record on GitHub. The gate has no override flag.
- R9. If a PR merges while its ticket still has an unlanded blocker, the orchestrator raises a critical attention naming both tickets. This is a detective control for merges that skipped the gate, for example a merge made in the GitHub UI.
- R10. A restack-only push does not cost a fresh review. The merge helper re-approves when every commit since the approved head is an Aiur restack commit whose tree it can recompute exactly. Background: the ruleset sets `dismiss_stale_reviews_on_push: true`, so the push dismisses the approval.

### Key decisions

| ID | Decision | Reason |
|---|---|---|
| KD1 | Stacked PRs target the blocker branch while the blocker is open (GitHub-native stacking). The alternative was to always target `main` and rely only on the gate. | The Executor reviews only the dependent's diff, and GitHub's auto-retarget handles the hand-off. With an always-`main` base, the blocker code would be reviewed twice, and "approve dependent" would also approve blocker code. |
| KD2 | Restack with a fast-forward "restack merge" commit. It has parents `(dependent head, origin/main)`. Its tree comes from `git merge-tree --write-tree --merge-base=$(git merge-base HEAD F) origin/main HEAD`, where F is `refs/pull/<blocker>/head`. The alternative was `git rebase --onto origin/main <F>`. | A merge commit is a fast-forward, so there is no force-push, no race with a live agent's local commits, and no dependency on G2's `branch.force-push` publisher. Using F's merge-base as the base subtracts the blocker's changes exactly. The rebase arm needs a force-push and replays every dependent commit (merge commits drop their conflict resolutions). The Appendix shows that a plain merge conflicts where the custom-base merge is clean. |
| KD3 | Split the restack. The orchestrator does it when no run is live. The agent does it when a run is live, and conflicts go to the agent. | The orchestrator never writes a branch that a live agent is writing. The idle case (PR awaiting review) is the common one and needs no agent slot, which saves the 30-60 minute rework round trip the reviewer brief measured (5f). |
| KD4 | The merge-order gate lives in the Executor merge path, as an in-repo script that the merge helper and the aiur-run skill call. It is not a required status check. | `--admin` from the bypass actor skips required checks. A daemon-published required check would also block every non-ticket PR that the daemon never polls. The script is deterministic, works without the daemon, and fails closed. |
| KD5 | The gate condition is "every blocker's merge commit is an ancestor of the PR head", not just "every blocker is merged". | It proves both that the blocker landed and that the dependent was built and tested on top of it. That is one condition instead of two, and it also catches a dependent that never restacked. |
| KD6 | Add a detective attention on an out-of-order merge (R9) instead of a preventive daemon status. | It is cheap: it reuses the existing `pr.merged` event and the `blocked_by` cache, with no per-head status writes. It covers the GitHub UI path that KD4 cannot cover. |
| KD7 | A blocker closed `not_planned`, or with its PR closed unmerged, refuses the gate. The text points to removing the edge, then to G4's policy. | Fail closed. The G4 area owns what an optimistic dependent does when its blocker dies (`build_queue/readiness.ex:60-71` already classifies these as failed). |

### Scope boundaries

- In scope: base-repair carve-out, restack (orchestrator and agent paths), merge-order gate script, out-of-order attention, skill and doc text for each.
- Out of scope: when a dependent starts (G1); pulling blocker pushes mid-work and publishing `branch.force-push` (G2); blocker failure and waste policy (G4); slot priority (G5); merge queues; other repos' merge methods beyond the stated support (merge-commit and rebase merges also pass the ancestry gate, because the blocker's commits or merge commit are on `main`).

### Success criteria

- A two-ticket stack, where the blocker squash-merges with its branch deleted, ends with the dependent PR based on `main`, the diff showing only dependent files, and the blocker merge commit an ancestor of the head. No force-push and no agent dispatch happen when the dependent was idle.
- The gate script refuses (exit 2) a dependent whose blocker is open, whose base is not `main`, or whose head lacks the blocker merge commit. It accepts once the restack lands.

### Seams with other areas (assumed interfaces)

- G1 sets when a dependent starts. G3 needs nothing from G1. The gate holds whatever trigger G1 chose.
- G2 opens the dependent PR with `--base <blocker head branch>` (KD1) and integrates blocker pushes by merge (current `.claude/skills/aiur-agent/dev-loop.md:50`). G3-1 is what lets that base survive the CI poller. G3 does not need `ticket.<n>.branch.force-push`, because restacks fast-forward. If G2 lets agents rebase, G2 owns that publisher.
- G4 owns the policy for a blocker closed unmerged. G3's gate only refuses, and the restack only runs on `pr.merged`.
- G5: the orchestrator restack takes no worker slot. A conflict rework enters the normal rework path and its priority.

## Outstanding questions for Kevin

- Q1. May the daemon push a fast-forward restack commit to an idle ticket branch with the agent token (KD3)? Recommended: yes. The push is the same identity agents already use, it is fast-forward only, and it is rejected if the remote moved.
- Q2. Should an approval that a restack push dismissed be re-applied automatically by the merge helper when its recomputed tree matches (R10)? Recommended: yes. Without it, every optimistic dependent costs one extra human-visible review.

## Appendix: restack reproduction (git 2.55)

Setup: the blocker edits line `b` and later line `g`. The dependent edits the blocker's `B1` line to `B1-dep`, merges the blocker's later push, and adds file `g`. Separately, `main` gains an unrelated commit and then the blocker's squash.

- `git merge-tree --write-tree main dep` gives `CONFLICT (content): Merge conflict in f`, exit 1.
- `git merge-tree --write-tree --merge-base=$(git merge-base dep F) main dep` gives exit 0. The commit `commit-tree <tree> -p dep -p main` is a fast-forward of `dep`. `git diff main <commit>` shows only `B1 -> B1-dep` and the new file `g`.

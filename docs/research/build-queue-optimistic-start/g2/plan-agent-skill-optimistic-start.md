---
title: BQ-G2-2 Teach the worker the optimistic-start loop - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g2/brainstorm.md
epic: aiur-team/aiur#3755
code_baseline: origin/main 0e5b8d0de
depth: Standard
---

# BQ-G2-2 Teach the worker the optimistic-start loop - Plan

## Summary

Add an "Optimistic start" mode to the `aiur-agent` skill and the shared agent prompt: a worker that was started on an unmerged blocker pulls every blocker push, rebases when the blocker's history is rewritten, keeps its PR stacked and in draft, parks when its own work is done, and follows G3's restack after the blocker merges. Covers brainstorm R5-R9; KD4, KD6, KD7, KD11.

Product Contract preservation: unchanged.

## Problem Frame

The skill models a dependent only as *paused until readiness*: "never infer readiness from `branch.push`", resume on `agent.unblocked` / `pr.merged` (`.claude/skills/aiur-agent/stub-then-fetch.md`, `emit-and-subscribe.md` default-subscriptions section, `src/prompts/shared-agent-instructions.md` cross-ticket events). An optimistically dispatched worker is not waiting for readiness; it is already building on the blocker's in-review code. Without a section for that mode it either ignores pushes (stale base) or misreads the "never infer readiness" rule as "do not integrate pushes".

## Requirements

- R5 on every `ticket.B.branch.push`, at the next safe checkpoint, fetch `ref`/`sha`, merge if fast-forward relative to the last integrated SHA, rerun tests affected by the incoming diff.
- R6 non-ancestor -> `git rebase --onto <new> <old>`, rerun tests, push the draft with `--force-with-lease`.
- R7 one blocker: PR base = blocker branch; several: base branch. Draft only; never `ci-wait` / `human-review` while a blocker PR is unmerged.
- R8 own work done + blocker unmerged -> emit `blocked` (`reason: "awaiting_blocker_merge"`) and `pause.request` (`reason: "dependency"`, `blocker_identifier`).
- R9 on `ticket.B.pr.merged` follow G3's restack section.

## Key Technical Decisions

- **One canonical section in `stub-then-fetch.md`**, titled "Optimistic start (started on an unmerged blocker)". Other files point to it. Avoids four drifting copies.
- **Trigger for the mode is the prompt's "Optimistic start" block** (written by BQ-G2-1), not an agent guess. Without the block, the existing paused-dependent rules apply unchanged.
- **Track the last integrated blocker SHA in the workpad.** The rebase decision needs `<old>`; the workpad survives turns and re-dispatch, unlike shell state.
- **Local ancestry check is authoritative** (KD7). `branch.force-push` is a hint that the check will fail; the worker runs the check on every push regardless.
- **Merge, not rebase, for fast-forward pushes** (KD6): keeps the worker's own history stable while the draft is shared with CI.
- **"Affected tests"** = the repository's documented affected-test command (for Aiur core, `mix aiur.affected_tests` over the incoming diff) plus the worker's own touched tests. The skill names the rule; the per-repo command stays in `dev-loop.md`.
- **Reconcile with "never infer readiness from branch.push".** Reword: a push is never a *readiness* signal for a paused dependent; for an optimistic worker it is an *integration* signal. Both statements appear side by side so neither reads as contradicting the other.

## Implementation Units

### U1. Canonical optimistic-start section

**Goal:** One procedure the worker follows from first turn to blocker merge.
**Requirements:** R5-R9.
**Dependencies:** none (references the BQ-G2-1 prompt block by name; inert until it ships).
**Files:** `.claude/skills/aiur-agent/stub-then-fetch.md`.
**Approach:** New section with: how to recognise the mode (prompt block); first-turn check (`merge-base --is-ancestor <sha> HEAD`, merge any missing head, record SHAs in workpad); per-push loop (checkpoint = WIP committed, no test run in flight; fetch payload ref/sha; ancestry check; merge or `rebase --onto`; affected tests; push; update workpad SHA); force-push handling; PR rules (draft, base per prompt, no ready / no `ci-wait` / no `human-review` while unmerged); park rule (R8 event payloads as JSON examples, matching the existing examples' style); after merge -> "follow the restack steps in <G3 section>" (link text finalised when G3 lands; until then: retarget the PR to `$AIUR_BASE_BRANCH`, rebase onto the base tip dropping commits already in the squash, rerun tests, then normal CI handoff). Add one row to "What NOT to do": do not mark ready, do not merge a rewritten blocker branch.
**Test expectation:** none -- skill prose. Covered by U4's prompt contract test and the dev-daemon dry run.
**Verification:** a reviewer can follow the section end to end for: one push, one force-push, blocker merge, without consulting another file.

### U2. Pointers in the other skill files

**Goal:** Every place an agent lands on blocker events sends it to U1 when in optimistic mode.
**Requirements:** R5, R6.
**Dependencies:** U1.
**Files:** `.claude/skills/aiur-agent/dev-loop.md` ("Integrating an upstream blocker's branch" paragraph; PR-creation step that hard-codes `--base "$AIUR_BASE_BRANCH"` gains "unless your prompt has an Optimistic start block"), `.claude/skills/aiur-agent/emit-and-subscribe.md` (default-subscriptions section: dispatch can create the `blocker:auto` bindings too; an optimistic worker treats `branch.push` as an integration signal), `.claude/skills/aiur-agent/overview.md` (delivery contract bullet; fix the drain allowlist to include `branch.force-push` and `pr.merged`, which the code already drains), `.claude/skills/aiur-agent/SKILL.md` (one routing line).
**Approach:** Short pointer sentences only; no duplicated procedure.
**Test expectation:** none -- prose.
**Verification:** `rg -n "Optimistic start" .claude/skills/aiur-agent` hits each file; no file restates the procedure.

### U3. Shared agent prompt

**Goal:** The reflex is in every prompt even before the skill loads.
**Requirements:** R5-R8.
**Dependencies:** U1.
**Files:** `src/prompts/shared-agent-instructions.md` (cross-ticket events bullets).
**Approach:** Add one bullet "Optimistic start": if your prompt has an Optimistic start block, every blocker push is an integration signal: integrate it at the next safe checkpoint, rebase on rewritten history, keep the PR draft and stacked as the block says, never mark ready while the blocker PR is unmerged; load `aiur-agent` `stub-then-fetch.md`. Adjust the "Resume on explicit unblocked" bullet so it is scoped to paused dependents.
**Test scenarios:** see U4.
**Verification:** U4 tests green.

### U4. Prompt contract test

**Goal:** The shared prompt keeps the optimistic-start rule.
**Requirements:** R5, R7.
**Dependencies:** U3.
**Files:** `src/test/aiur/prompt_builder_test.exs` (or the existing shared-instructions contract test if one exists; check `rg -n "shared-agent-instructions" src/test`).
**Test scenarios:**
- The built prompt contains "Optimistic start", "next safe checkpoint", "--force-with-lease", and "never mark ready" phrases.
- The "Resume on explicit unblocked" bullet still says readiness is never inferred from `branch.push` alone.
**Verification:** tests green.

## Scope Boundaries

- Not in scope: orchestrator changes (BQ-G2-1), force-push publication (BQ-G2-3), G3 restack procedure text (link only).
- The `emit-and-subscribe.md` note "no publisher emits force-push" is changed by BQ-G2-3, not here.

## Risks

- **Agents over-integrate mid-test.** The checkpoint definition (WIP committed, no test run in flight) and batching (integrate only the latest push when several queued) limit churn.
- **Force-push of the dependent's draft.** Allowed only with `--force-with-lease` and only while the PR is draft; recorded as an operator-visible assumption in the brainstorm.
- **Text before code.** U1 is keyed on the prompt block, so shipping before BQ-G2-1 changes nothing for running agents.

## Documentation

- `website/docs-app/concepts/ticket-lifecycle.md` (Build queue): short "Optimistic dependents" paragraph pointing to the behavior.

## Verification Contract

- U4 tests; skill files render; dev-daemon dry run once BQ-G2-1 is live: push twice to a blocker branch (one fast-forward, one rewrite) and observe the dependent's workpad SHAs and branch history follow R5/R6.

## Definition of Done

Skill + prompt merged; contract test green; dry run recorded on the ticket.

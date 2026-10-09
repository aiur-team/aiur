---
title: MP6 Executor adoption - Plan
type: chore
date: 2026-10-09
topic: merge-policy
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/merge-policy/brainstorm.md
base_main_sha: fd158cef8
---

# MP6 Executor adoption - Plan

## Goal Capsule

- **Objective:** the committed Executor guidance follows `merge_policy`, names
  `aiur pr merge` as the only merge path, and the scratch scripts are retired.
- **Product authority:** [brainstorm.md](brainstorm.md) (R16).
- **Open blockers:** MP2, MP3, MP5.
- **Product Contract preservation:** unchanged.

---

## Problem Frame

`.claude/skills/aiur-run/SKILL.md` (about line 1228) and
`.claude/skills/aiur-run/references/executor.md` (about line 486) say "never
merge a pending, failing, or stale head", which contradicts the aiur repo's
rule. `ci_lifecycle.ex` tells the Executor to run `gh pr merge --auto` for a
parked-ready PR. `docs/security/human-only-merge-gate.md` says the bypass
"cannot merge a red build", which is false.

## Requirements

- R16 from the brainstorm.
- MP6-R1. Guidance says: read `aiur status` for the merge policy; merge only
  with `aiur pr merge`; under `pending_ok` merge on reviewed local evidence;
  on `system.main.ci.failed` check the fixer ticket, do not fix main by hand
  unless the fixer is stalled.
- MP6-R2. Review guidance checks the `Local tests` evidence (MP3 format).
- MP6-R3. The parked-ready message names `aiur pr merge <N> --reviewed-sha
  <sha>`.
- MP6-R4. The merge-gate doc states that the bypass skips required checks and
  that `aiur pr merge` refuses failed checks.

## Implementation Units

### U1. Skill and reference text

**Files:** `.claude/skills/aiur-run/SKILL.md`,
`.claude/skills/aiur-run/references/executor.md`,
`.claude/skills/aiur-handoff/SKILL.md` (handoff records the policy from
`aiur status`, not a memory note).
**Test expectation:** none -- prose; reviewer checks no "never merge a
pending" absolute remains.

### U2. Parked-ready message

**Files:** `src/lib/aiur/orchestrator/ci_lifecycle.ex`,
`src/test/aiur/orchestrator_ci_lifecycle_test.exs`.
**Test scenarios:** parked-ready event text contains `aiur pr merge <N>
--reviewed-sha <head>`.

### U3. Merge-gate doc

**Files:** `docs/security/human-only-merge-gate.md`.
**Test expectation:** none -- docs.

### U4. Retire scripts (operator step)

**Approach:** the PR description lists the operator steps: stop
`main-watch.sh`, delete `merge-if-safe.sh`, drop rules 5b and 6 from the
reviewer brief in favor of the skill text, update the memory note to point
at `merge_policy`.
**Test expectation:** none -- operator machine.

## Verification Contract

- A fresh Executor session that reads only the skill and `aiur status`
  merges a PR with pending CI on the aiur repo and refuses on a repo with
  `ci: wait`.

## Definition of Done

- Merged; the scratch scripts are no longer used.

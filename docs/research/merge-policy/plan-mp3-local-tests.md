---
title: MP3 Local-tests mode and PR evidence - Plan
type: feat
date: 2026-10-09
topic: merge-policy
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/merge-policy/brainstorm.md
base_main_sha: fd158cef8
---

# MP3 Local-tests mode and PR evidence - Plan

## Goal Capsule

- **Objective:** every worker prompt states the repo's `local_tests` mode in
  plain words, and every PR body carries the commands the agent ran and their
  results for the head it pushed. Reviewers check that evidence.
- **Product authority:** [brainstorm.md](brainstorm.md) (R8, R9, R10). Kevin,
  2026-10-09: "require_local_tests should have option: all, partial, none.
  which should tell the agent. partial is only relevant to the change".
- **Open blockers:** MP1 (config).
- **Product Contract preservation:** unchanged.

---

## Problem Frame

`src/prompts/shared-agent-instructions.md` and
`.claude/skills/aiur-agent/dev-loop.md` tell agents to run affected tests, but
the PR template has only a `make -C elixir all` checkbox and no results. A
reviewer cannot tell what ran. Under `pending_ok`, that evidence is the only
proof before merge.

## Requirements

- R8, R9, R10 from the brainstorm.
- MP3-R1. The prompt section is rebuilt from config on every turn and is
  restated to long-lived agents when the policy changes.
- MP3-R2. `mix pr_body.check` validates the `Local tests` section shape.
- MP3-R3. MP2 parses the same section; the format has one parser shared by
  both.

## Key Technical Decisions

- **Prompt text per mode** (directional):
  - `all`: "Before marking the PR ready, run the full local test suite for this
    repo. Record each command and its result line in the PR body."
  - `partial`: "Run only the tests relevant to your change: the tests you
    changed, the mirror test of each source file you changed, tests of direct
    callers of changed modules, and tests that still use a name you deleted.
    If the change touches shared test support, build files, dependency files or
    runtime config, run the full suite instead. In this repo, `mix
    aiur.affected_tests` computes the set." (The last sentence comes from the
    repo's own setup notes, not hardcoded.)
  - `none`: "Run compile and format checks. CI is the test gate."
  - When `ci: pending_ok`, add: "Your PR may merge before CI finishes, on this
    evidence. A missing or stale `Local tests` section makes it wait for CI."
- **Section format**, under heading `## Local tests`:

  ```text
  Policy: partial
  Tested head: <full 40-char sha>
  Base: origin/main @ <sha>
  Selection: mix aiur.affected_tests -> 7 files (mirror + 2 xref dependents)
  - `mise exec -- mix test test/aiur/foo_test.exs ...` -> 42 tests, 0 failures
  - `mise exec -- mix format --check-formatted` -> ok
  ```

  `Tested head` must be the commit pushed. An agent that pushes again updates
  the section.
- **Template change:** replace the Test Plan section of
  `.github/pull_request_template.md` with `Local tests`, so
  `pr_body.check` requires it everywhere. Add `pr_body.check` to CI's
  workflow-security job (it exists but CI does not run it).
- **Prompt builder pattern:** a `merge_policy_prompt/0` beside
  `integration_branch_prompt/1`, plus a restatement function like
  `integration_branch_restatement/0`.
- **Reviewer guidance lives in skills, not the daemon.** The aiur-run review
  prompt (MP6) checks: section present, `Tested head` = PR head, selection
  covers changed files, results show 0 failures.

## Implementation Units

### U1. Evidence format module

**Goal:** one parser and validator for the section.
**Requirements:** R10, MP3-R3.
**Files:** `src/lib/aiur/local_test_evidence.ex` (new),
`src/test/aiur/local_test_evidence_test.exs` (new).
**Test scenarios:**
- Well-formed section: parsed policy, head, commands, results.
- Short SHA in `Tested head`: invalid (must be 40 hex).
- Section missing: `:missing`.
- `Policy: none` while config says `partial`: invalid "policy below repo
  mode".
- A command line with no `->` result: invalid.

### U2. Prompt section and restatement

**Goal:** agents are told the mode.
**Requirements:** R8, R9, MP3-R1.
**Files:** `src/lib/aiur/prompt_builder.ex`,
`src/test/aiur/prompt_builder_test.exs`.
**Test scenarios:**
- Each of `all`, `partial`, `none` renders its paragraph.
- `pending_ok` adds the early-merge sentence; `wait` does not.
- Policy change between turns: the restatement contains the new mode.

### U3. Shared instructions and skill

**Goal:** static text matches the config-driven text.
**Requirements:** R8, R10.
**Files:** `src/prompts/shared-agent-instructions.md` (sections "A finished
ticket is a ready PR" and "Local pre-handoff checks": defer to the prompt's
policy section; add the evidence rule), `.claude/skills/aiur-agent/dev-loop.md`
(local gate and PR-opening steps), `.claude/skills/aiur-agent/validation.md`.
**Test expectation:** none -- prose; covered by U2's rendered prompt test and
reviewer read.

### U4. PR template and body check

**Goal:** the section is required and checked.
**Requirements:** MP3-R2.
**Files:** `.github/pull_request_template.md`,
`src/lib/mix/tasks/pr_body.check.ex`, `src/test/mix/tasks/pr_body_check_test.exs`,
`.github/workflows/ci.yml` (run `mix pr_body.check` on PR events).
**Test scenarios:**
- Body with the template's placeholder left in: fails.
- Body with a valid section: passes.
- Body missing `Local tests`: fails naming the heading.

## Scope Boundaries

- No generic affected-test tool for non-Elixir repos; the prompt defines the
  rule and the repo's setup notes name its tool.

## Risks

- Agents may write evidence they did not run. Reviewers compare the evidence
  with the diff, and main-watch catches what slips through.

## Verification Contract

- Unit tests for U1, U2, U4; one real agent PR after rebuild carries a valid
  section.

## Definition of Done

- Merged and rebuilt; the next dispatched aiur ticket's PR has a valid
  `Local tests` section without Executor prompting.

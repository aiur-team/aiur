---
title: refactor: Bound agent test concurrency
type: refactor
status: completed
date: 2026-07-09
---

# refactor: Bound agent test concurrency

## Summary

Update the agent workflow prompt so scoped affected-test runs use ExUnit's four-case concurrency cap. The guard preserves local correctness verification while preventing a single agent from monopolizing shared CPU schedulers.

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that should be reviewed before implementation proceeds.*

- A fixed cap of four concurrent ExUnit cases is the intended fleet-wide default from the issue's suggested value.

## Requirements

- R1. The prompt and operating manual require affected test runs to use `mix test --max-cases 4`.
- R2. The existing affected-tests-only policy and all other scoped pre-PR checks remain intact across both sources.
- R3. A regression test detects removal of the concurrency cap from the prompt.

## Scope Boundaries

- Do not alter ExUnit's project-level configuration or CI test parallelism.
- Do not broaden the local test gate back to a full test suite.
- Do not change the adjacent local Credo policy; it is owned by #873.

## Context & Research

### Relevant Code and Patterns

- `.aiur/prompt.md` is the repository-specific template injected into issue-worker prompts.
- `src/test/aiur/aiur_agent_skill_test.exs` already guards the local pre-PR workflow language in that template.
- `.claude/skills/using-aiur/dev-loop.md` is the operating manual that the template directs agents to follow.

## Implementation Units

### U1. Bound affected-test prompt guidance

**Goal:** Make bounded ExUnit concurrency mandatory for every affected test invocation.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `.aiur/prompt.md`
- Modify: `.claude/skills/using-aiur/dev-loop.md`

**Approach:**
- Add the `--max-cases 4` requirement immediately after the existing affected-tests-only policy in both live workflow sources, retaining each source's scoped verification language.

**Patterns to follow:**
- Preserve the existing single-bullet workspace setup guidance.

**Test scenarios:**
- Test expectation: none -- template-only wording change.

**Verification:**
- The rendered source clearly requires the bounded command while retaining the scoped gate.

### U2. Guard the prompt contract

**Goal:** Prevent future edits from removing the bounded-concurrency instruction.

**Requirements:** R3

**Dependencies:** U1

**Files:**
- Modify: `src/test/aiur/aiur_agent_skill_test.exs`

**Approach:**
- Extend the existing scoped-pre-PR guidance test with an assertion for the exact capped command.

**Patterns to follow:**
- Reuse the test's normalized prompt-string assertions.

**Test scenarios:**
- Happy path: the shipped prompt includes `mix test --max-cases 4`.

**Verification:**
- The focused agent-skill test passes.

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| A future wording cleanup drops the cap | The focused source assertion fails. |
| Agents interpret the cap as permission to skip tests | The change retains the existing affected-tests-only requirement. |

## Sources & References

- Related issue: #876
- Related issue: #873

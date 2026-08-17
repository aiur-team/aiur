---
title: refactor: Bound agent test concurrency
type: refactor
status: completed
date: 2026-07-09
---

# refactor: Bound agent test concurrency

## Summary

Enforce a four-scheduler cap on every Mix VM launched by an agent. ExUnit derives its default case count from online schedulers, so this bounds affected, full-suite, and coverage test shapes without relying on a prompt instruction. Keep the prompt guidance as secondary documentation.

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that should be reviewed before implementation proceeds.*

- A fixed cap of four concurrent ExUnit cases is the intended fleet-wide default from the issue's suggested value.

## Requirements

- R1. The prompt and operating manual require affected test runs to use `mix test --max-cases 4`.
- R2. The existing affected-tests-only policy and all other scoped pre-PR checks remain intact across both sources.
- R3. Agent-launched Mix VMs default to four schedulers, including when the workflow omits an explicit cap.
- R4. Local and remote agent environments both carry the configured scheduler cap and effective ERTS options.
- R5. A behavior test observes the configured scheduler count from a spawned Mix VM.

## Scope Boundaries

- Do not alter ExUnit's project-level configuration or CI test parallelism.
- Do not broaden the local test gate back to a full test suite.
- Do not change the adjacent local Credo policy; it is owned by #873.

## Context & Research

### Relevant Code and Patterns

- `.aiur/prompt.md` is the repository-specific template injected into issue-worker prompts.
- `src/test/aiur/aiur_agent_skill_test.exs` already guards the local pre-PR workflow language in that template.
- `.claude/skills/aiur-agent/dev-loop.md` is the operating manual that the template directs agents to follow.
- `Aiur.AgentEnvironment` supplies the local Port and remote SSH environments inherited by agent-launched Mix processes.
- `agent.mix_scheduler_cap` and the `AIUR_AGENT_MIX_SCHEDULERS` launcher convention already exist; this plan activates them with a default and propagation path.

## Implementation Units

### U1. Bound affected-test prompt guidance

**Goal:** Make bounded ExUnit concurrency mandatory for every affected test invocation.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `.aiur/prompt.md`
- Modify: `.claude/skills/aiur-agent/dev-loop.md`

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

### U3. Enforce the Mix scheduler cap

**Goal:** Bound every agent-launched Mix VM to the configured scheduler count, regardless of test command shape.

**Requirements:** R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/config/schema/agent.ex`
- Modify: `src/lib/aiur/config.ex`
- Modify: `src/lib/aiur/agent_environment.ex`
- Modify: `src/test/aiur/app_server/adapter_test.exs`
- Modify: `src/test/aiur/agent_environment_test.exs`

**Approach:**
- Default `agent.mix_scheduler_cap` to four and preserve a four-scheduler fallback for legacy workflow files.
- Inject both the scheduler-cap marker and normalized `ELIXIR_ERL_OPTIONS` into local Port and remote SSH launches, replacing any inherited `+S` setting so configured policy wins.
- Run a real child Mix VM from the app-server launch seam with an override value and assert its online scheduler count matches that value.

**Test scenarios:**
- Happy path: an omitted cap resolves to four in agent environment exports.
- Override: a workflow cap of three reaches a spawned Mix VM as three online schedulers.
- Integration: remote export text carries the same marker and ERTS options as local launch environments.

**Verification:**
- Focused app-server adapter and agent-environment tests pass with `--max-cases 4`.

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| An agent omits `--max-cases` or runs a different Mix test shape | The child Mix VM still has four schedulers, so ExUnit's default remains bounded. |
| An inherited launcher cap conflicts with workflow policy | Agent environment normalization replaces inherited `+S` options with the configured cap. |
| Agents interpret the cap as permission to skip tests | The change retains the existing affected-tests-only requirement. |

## Sources & References

- Related issue: #876
- Related issue: #873

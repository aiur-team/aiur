---
date: 2026-06-24
topic: agent-synthetic-load-containment
---

# Agent Synthetic Load Containment

## Summary

Aiur should prevent one running agent from starving sibling agents by bounding synthetic CPU load-generator descendants in that agent's local process tree. The shared prompt should also steer agents toward deterministic flake reproduction and small, promptly stopped load generators.

---

## Problem Frame

During dogfood runs with multiple concurrent agents, an agent reproducing a load-sensitive flake spawned 16 `yes` workers under its workspace shell. That was reasonable in isolation but harmful in a shared run: the host load spiked, sibling agents stopped making progress, and the operator had to pause the offending ticket and terminate the process group manually.

The existing load gate protects future dispatch decisions when the host is already hot. It does not contain an agent that is already running and self-spawns high-count load generators.

---

## Assumptions

*This requirements doc was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input -- un-validated bets that should be reviewed before planning proceeds.*

- The first shippable containment target is known synthetic CPU load generators such as `yes`, `stress`, and `stress-ng`, not every CPU-heavy child process an agent might run.
- Trimming excess generator descendants is preferable to killing the whole agent, because the agent can continue its turn, observe the failed repro, and adjust.
- Local OS process trees are in scope for this PR; remote worker hosts can receive equivalent enforcement later.

---

## Actors

- A1. Operator: Runs Aiur with multiple concurrent agents and needs shared host capacity to remain usable.
- A2. Reproducing agent: Runs tests or flake repro scripts that may intentionally create synthetic CPU load.
- A3. Sibling agents: Continue unrelated work on the same host and should not be starved by another agent's repro.

---

## Key Flows

- F1. Synthetic load repro containment
  - **Trigger:** A running agent starts more load-generator descendants than the configured per-agent cap.
  - **Actors:** A2, A3
  - **Steps:** Aiur observes the registered agent process root, identifies load-generator descendants, preserves up to the cap, and terminates the excess generator processes only.
  - **Outcome:** The repro is constrained before it can monopolize the shared host, while non-generator descendants continue.
  - **Covered by:** R1, R2, R3

- F2. Agent prompt guidance
  - **Trigger:** An agent decides how to reproduce a load-sensitive flake.
  - **Actors:** A2, A3
  - **Steps:** The shared instructions prefer deterministic approaches and require any synthetic load workers to be capped and stopped promptly.
  - **Outcome:** Agents avoid fixed high-count CPU burners in shared runs unless there is a clear need.
  - **Covered by:** R4

---

## Requirements

**Runtime containment**
- R1. When a running local agent process tree contains more known synthetic load-generator descendants than the cap, Aiur terminates the excess generator descendants.
- R2. Aiur must not terminate ordinary child processes solely because they belong to the same process tree as excess load generators.
- R3. The generator cap must be operator-configurable, disabled by explicit configuration, and default to a small cores-scaled value.

**Agent behavior guidance**
- R4. Shared agent instructions must discourage brute CPU load repros and direct agents to cap any necessary load generators to a small fraction of available cores.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R3.** Given a registered local agent root with 16 `yes` descendants, one `mix test` descendant, and a cap of 3, when the guard runs, only 13 excess `yes` descendants are terminated and the `mix test` process is preserved.
- AE2. **Covers R3.** Given the operator disables the cap, when the guard runs, it does not inspect or terminate load-generator descendants.
- AE3. **Covers R4.** Given an agent is deciding how to reproduce a flake, when it reads the shared instructions, it is told to prefer deterministic methods and avoid fixed high-count load generators on the shared host.

---

## Success Criteria

- A single agent's `yes`/`stress`-style repro cannot drive host load unboundedly by spawning a fixed high worker count.
- Sibling agents continue making progress during another agent's load-sensitive flake repro.
- Downstream planning and review can distinguish the runtime containment scope from future broader CPU quota work.

---

## Scope Boundaries

- Do not require root permissions, cgroup delegation, `cpulimit`, or a working user-systemd bus for the first fix.
- Do not change the existing dispatch load gate.
- Do not attempt to classify or kill all CPU-heavy children.
- Do not enforce remote worker process trees in this PR.

---

## Key Decisions

- Runtime containment should fail open when host process inspection is unavailable, preserving Aiur stability over perfect enforcement.
- Prompt guidance should remain complementary to runtime containment; instructions reduce bad-neighbor behavior, but enforcement handles repeated failures.

---

## Dependencies / Assumptions

- Local agents register usable OS process roots with Aiur's process reaper.
- The shared host exposes process parent/child information to the Aiur process.

---

## Outstanding Questions

### Deferred to Follow-Up Work

- [Affects R1][Operational] Should future work add cgroup or quota-based containment for all CPU-heavy agent descendants once deployment constraints are better understood?

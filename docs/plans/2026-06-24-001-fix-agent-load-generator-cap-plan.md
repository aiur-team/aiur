---
title: fix: Cap agent synthetic load generators
type: fix
status: active
date: 2026-06-24
---

# fix: Cap agent synthetic load generators

## Summary

Bound the specific bad-neighbor pattern from #479 by monitoring registered agent process trees and trimming synthetic CPU load-generator descendants above a cores-scaled cap. Pair the runtime guard with shared-prompt guidance so agents prefer deterministic flake repros and keep load generators small.

---

## Problem Frame

One agent can legitimately try to reproduce a load-sensitive flake, but in a shared Aiur run that same repro can spawn enough CPU burners to starve sibling agents. The existing host load gate only holds new dispatch; it does not constrain an agent that is already running.

---

## Assumptions

- The immediate live failure mode to contain is `yes`/`stress`-style synthetic load generators spawned inside an agent workspace, not every possible CPU-heavy workload.
- Killing excess load-generator descendants is safer than killing the whole agent, because the agent can still report the failed repro or adjust the command.
- Remote worker hosts may need equivalent enforcement later; this plan focuses on local registered OS process trees.

---

## Requirements

- R1. With an agent running a high-count `yes` load repro, Aiur trims generator processes to a small fraction of available cores.
- R2. Normal agent child processes are not killed just because they belong to the same process tree.
- R3. The cap is configurable and defaults to `max(1, schedulers_online / 4)`.
- R4. Agents are explicitly instructed to avoid brute-force synthetic load and cap any necessary load generators.

---

## Scope Boundaries

- Do not require root, cgroup delegation, `cpulimit`, or a working user-systemd bus.
- Do not change the dispatch load gate from #465.
- Do not enforce remote-worker process trees in this PR.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/process_reaper.ex` is the existing registry for agent OS PIDs and pane refs.
- `src/lib/aiur/claude/remote_control.ex` already has process-tree kill helpers and `/proc`/`pgrep` patterns.
- `src/lib/aiur/config/schema.ex` and `src/lib/aiur/config.ex` define agent-level runtime knobs.
- `src/prompts/shared-agent-instructions.md` carries repository-wide operator guidance injected into agent prompts.

---

## Key Technical Decisions

- Add a dedicated `Aiur.AgentResourceGuard` GenServer instead of embedding periodic work inside `ProcessReaper`: keeps shutdown cleanup and runtime policy separate.
- Use `ProcessReaper.entries/0` as the source of registered agent roots: avoids duplicating backend registration paths.
- Kill only known synthetic load-generator commands above the cap: this addresses the observed failure while avoiding false positives against ordinary compile/test children.

---

## Implementation Units

### U1. Add configurable load-generator cap

**Goal:** Add `agent.synthetic_load_process_cap` with a default derived from schedulers.

**Requirements:** R3

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/config/schema.ex`
- Modify: `src/lib/aiur/config.ex`
- Modify: `.aiur/examples/config.example`
- Test: existing config tests if a focused assertion is needed

**Approach:**
- Accept `nil` for the derived default, `0` to disable, and positive integers for explicit caps.
- Expose a config accessor that resolves nil to `max(1, div(System.schedulers_online(), 4))`.

**Test scenarios:**
- Happy path: absent config resolves to the derived cap.
- Edge case: `0` disables the guard.

**Verification:**
- Config parses existing examples and the accessor returns the intended values.

### U2. Implement process-tree synthetic load guard

**Goal:** Periodically inspect registered agent roots and terminate excess synthetic load-generator descendants.

**Requirements:** R1, R2

**Dependencies:** U1

**Files:**
- Create: `src/lib/aiur/agent_resource_guard.ex`
- Modify: `src/lib/aiur.ex`
- Modify: `src/lib/aiur/process_reaper.ex`
- Test: `src/test/aiur/agent_resource_guard_test.exs`

**Approach:**
- `ProcessReaper.entries/0` returns registered refs with kind/meta for read-only consumers.
- The guard filters local `:agent` `{:os_pid, pid}` roots, walks descendants with `pgrep -P`, classifies known synthetic load commands (`yes`, `stress`, `stress-ng`), and kills only processes above the cap.
- Tests inject tree/process-info/kill functions so they do not touch host processes.

**Test scenarios:**
- Happy path: a process tree with 16 `yes` descendants and cap 3 kills only 13 excess `yes` PIDs.
- Edge case: non-load descendants are preserved.
- Edge case: cap 0 disables enforcement.

**Verification:**
- Targeted guard tests pass without spawning real load.

### U3. Update shared agent guidance

**Goal:** Discourage agents from recreating the bad neighbor pattern.

**Requirements:** R4

**Dependencies:** None

**Files:**
- Modify: `src/prompts/shared-agent-instructions.md`

**Approach:**
- Add a concise rule near the dev loop/tooling guidance: prefer deterministic flake repros; when synthetic load is necessary, cap workers to `max(1, cores / 4)` and stop them promptly.

**Test scenarios:**
- Test expectation: none -- prompt text only.

**Verification:**
- Shared prompt contains the guidance without conflicting with existing manual verification rules.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Unknown load generators evade the classifier | Start with the live `yes`/`stress` pattern and keep the prompt guidance; expand classifier only with evidence. |
| Killing too aggressively breaks valid tests | Preserve the first capped generators and kill only known load-generator commands, not arbitrary CPU-heavy children. |
| `/proc`/`pgrep` unavailable | Guard fails open, matching existing Linux-only load-gate behavior. |

---

## Documentation / Operational Notes

- Operators can set `agent.synthetic_load_process_cap: 0` to disable, or a positive integer to override the cores-derived default.

---

## Sources & References

- Related issue: #479
- Origin requirements: `docs/brainstorms/2026-06-24-agent-synthetic-load-containment-requirements.md`
- Related code: `src/lib/aiur/process_reaper.ex`
- Related code: `src/lib/aiur/claude/remote_control.ex`
- Related prompt: `src/prompts/shared-agent-instructions.md`

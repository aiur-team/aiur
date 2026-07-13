---
title: "fix: Re-ramp AIMD capacity from CPU headroom"
type: fix
status: completed
date: 2026-07-12
---

# fix: Re-ramp AIMD capacity from CPU headroom

## Summary

Let the adaptive dispatch envelope recover quickly after backoff when short-window host CPU measurements show genuine idle capacity. The existing one-minute-load hard gate and multiplicative backoff remain unchanged; each poll continues scanning queued tickets and automatically fills the newly exposed slots.

## Problem Frame

The current envelope uses the same lagging one-minute load sample for both safety backoff and recovery. After a transient spike halves effective concurrency, additive growth can leave dispatchable work queued for many polls even though the CPUs are mostly idle.

## Assumptions

- Linux `/proc/stat` delta samples are the portable local source for real CPU idle percentage, while its `procs_running` field supplies an instantaneous queue-pressure guard.
- A clearly idle host can safely recover with bounded multiplicative steps because the unchanged hard gate, memory gate, file-descriptor gate, build staggering, and future multiplicative decreases remain independent protections.
- Existing issue polling already auto-dispatches every eligible queued ticket up to available slots, so no manual-pause override or separate resume path should be introduced.

## Requirements

- R1. Preserve the existing hard load gate and multiplicative/cooldown backoff behavior.
- R2. When CPU idle headroom is clearly available, runnable pressure is low, queued work exists, and effective capacity is below the static/session cap, restore dispatch capacity within one or two polls.
- R3. Missing or malformed real-CPU telemetry must fall back to the existing additive recovery behavior.
- R4. Newly available slots must be consumed by the normal queued-ticket dispatch loop without manual `resume` calls.

## Scope Boundaries

- Do not weaken the one-minute-load hard gate or change high-load decrease/cooldown behavior.
- Do not change deliberate pause semantics, retry/reactivation bypasses, or per-state caps.
- Do not add configuration knobs until dogfood evidence shows the conservative idle/runnable thresholds need operator tuning.
- Operator-root TUI dogfood remains outside this agent workspace because `--test` is guarded here.

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/orchestrator/dispatch_policy.ex` owns pure envelope transitions and host admission sampling.
- `src/lib/aiur/orchestrator/dispatcher.ex` samples resources once per poll, updates the envelope, then reduces all eligible issues through normal dispatch.
- `src/lib/aiur/system_load.ex` demonstrates injectable `/proc` readers with fail-open parsing.
- `src/test/aiur/orchestrator_load_gate_test.exs` provides deterministic coverage of envelope transitions and resource-source short circuits.

### Institutional Learnings

- `docs/plans/2026-07-09-001-refactor-load-concurrency-envelope-plan.md` explicitly separates the adaptive envelope from the hard gate and requires running work to drain naturally.

### External References

- No external research is needed; Linux procfs contracts and repository-local source injection patterns fully cover the change.

## Key Technical Decisions

- Add a small `Aiur.SystemCpu` sampler that parses cumulative CPU counters and runnable count, leaving delta calculation in a pure helper so tests do not depend on live host timing.
- Store the prior cumulative CPU sample in orchestrator state. The first sample seeds history; the next poll can calculate idle percentage, satisfying the one-to-two-cycle recovery target.
- Treat fast recovery as a bounded multiplicative branch. If headroom is absent or unavailable, retain today's additive increase and all existing high-load behavior.
- Pass whether dispatchable queued work exists into the envelope update so idle telemetry alone never expands capacity without demand.

## Implementation Units

### U1. Add deterministic real-CPU headroom sampling

**Goal:** Produce a short-window CPU-idle percentage and runnable-count sample without blocking the poll loop.

**Requirements:** R2, R3

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/system_cpu.ex`
- Modify: `src/lib/aiur/orchestrator/state.ex`
- Test: `src/test/aiur/system_cpu_test.exs`

**Approach:** Parse aggregate counters and `procs_running` from `/proc/stat`, retain the prior counters in orchestrator state, and calculate idle percentage only from positive deltas. Return unavailable for missing, malformed, reset, or zero-delta samples.

**Patterns to follow:** `Aiur.SystemLoad` source overrides and fail-open return contract.

**Test scenarios:**
- Happy path: two valid cumulative samples yield the expected idle percentage and runnable count.
- Edge case: the first sample seeds history but has no idle percentage yet.
- Error path: malformed input, counter rollback, and zero total delta return unavailable headroom without crashing.

**Verification:** Unit tests exercise parsing and delta math without reading live procfs.

### U2. Fast-ramp demanded capacity under clear headroom

**Goal:** Restore the effective cap rapidly when queued work and real CPU headroom make additive recovery unnecessarily conservative.

**Requirements:** R1, R2, R3, R4

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/orchestrator/dispatch_policy.ex`
- Modify: `src/lib/aiur/orchestrator/dispatcher.ex`
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: `src/test/aiur/orchestrator_load_gate_test.exs`
- Test: `src/test/aiur/orchestrator/dispatcher_test.exs`

**Approach:** Sample real CPU beside existing resource samples. When demand exists, idle percentage is clearly high, and runnable pressure remains below scheduler capacity, grow multiplicatively while capping each poll to three new slots. Otherwise use the configured additive step exactly as today. Let the existing issue reduction consume all resulting slots in the same poll.

**Patterns to follow:** Pure `load_envelope/4` decisions, `update_load_envelope/5`, and `choose_issues/2` slot re-evaluation after each dispatch.

**Test scenarios:**
- Happy path: after a decrease, a seeded high-idle/low-runnable sample with queued work restores the cap on the following poll.
- Integration: multiple queued eligible issues are dispatched automatically into all restored slots during that poll.
- Edge case: high idle without queued demand keeps the existing envelope value.
- Edge case: high runnable pressure or unavailable CPU delta uses additive growth rather than fast-ramp.
- Regression: above-target load still halves capacity subject to cooldown, and load above the hard threshold still holds dispatch.

**Verification:** Focused policy and dispatcher tests demonstrate recovery within two samples and no manual resume path.

## System-Wide Impact

- **Interaction graph:** Procfs sample → orchestrator state delta → envelope transition → existing slot calculation → existing queued issue dispatch.
- **Error propagation:** Telemetry failures degrade to additive recovery and never stop dispatch by themselves.
- **State lifecycle risks:** CPU counters reset across boot/process lifetime; invalid deltas reseed rather than producing false headroom.
- **API surface parity:** Runtime/configured max-agent controls remain the upper bound and retain their current status output.
- **Unchanged invariants:** Hard CPU load, memory, FD, per-state, worker-host, and thrash gates still independently veto dispatch.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A brief idle window over-admits CPU-heavy agents | Require both a high idle percentage and low runnable pressure; retain the hard gate and immediate future backoff. |
| Procfs is unavailable off Linux | Fall back to the current additive algorithm. |
| Paused tickets are mistaken for dispatch demand | Derive demand from the same eligibility policy used by normal dispatch, not merely issue-list presence. |

## Documentation / Operational Notes

- No user-facing configuration changes are planned.
- Operator-root dogfood should verify a transient spike/backoff followed by automatic refill with rendered agent-list/chat evidence.

## Sources & References

- Related issue: #1029
- Original envelope plan: `docs/plans/2026-07-09-001-refactor-load-concurrency-envelope-plan.md`
- Related code: `src/lib/aiur/orchestrator/dispatch_policy.ex`
- Related tests: `src/test/aiur/orchestrator_load_gate_test.exs`

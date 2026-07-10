---
title: "refactor: Add load-based concurrency envelope"
type: refactor
status: completed
date: 2026-07-09
---

# refactor: Add load-based concurrency envelope

## Summary

Add a configurable AIMD-style dispatch envelope that ramps effective agent concurrency up below a target host load and reduces it after overshoot. The existing static/session cap and hard load gate remain independent upper bounds.

---

## Problem Frame

The fixed `agent.max_concurrent_agents` cap asks operators to choose a safe number before knowing the current workload. At a higher cap, several agents can begin CPU-heavy validation together and saturate the host before the existing hard load gate has a chance to prevent further admissions.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input -- un-validated bets that should be reviewed before implementation proceeds.*

- `agent.target_load_average` defaults to a conservative per-scheduler target below the existing `agent.max_load_average` hard ceiling, and explicit `null` disables only the adaptive envelope.
- The envelope begins at a small effective capacity, increases by a configurable additive step, and applies a multiplicative decrease after a configurable cooldown when load exceeds the target.
- Runtime `--max-agents` and `aiur set max-agents` remain the static/session ceiling; the envelope only restricts new dispatch and must not interrupt already-running agents.

---

## Requirements

- R1. Parse, validate, and document a per-scheduler target load, additive ramp step, and decrease cooldown under `agent` configuration.
- R2. While readable host load remains below the target, effective dispatch concurrency increases by the configured step without exceeding the static/session cap.
- R3. When readable host load exceeds the target and the cooldown permits an adjustment, effective concurrency decreases multiplicatively and never falls below one dispatch slot.
- R4. The existing `agent.max_load_average` hard gate remains a separate safety ceiling and continues to hold new dispatch above its threshold.
- R5. Unreadable host load fails open without changing the envelope; already-running agents are never stopped by the controller.
- R6. Focused tests characterize low-load growth, high-load decrease, cooldown behavior, and the configured/session-cap bound.

---

## Scope Boundaries

- Do not attempt CPU quotas, cgroups, or control of external processes; the controller only changes Aiur's future dispatch admission.
- Do not change the semantics of per-state caps, retries, reactivations, paused-slot reservation, or the existing runtime max-agent control surface beyond honoring the adaptive limit for new normal dispatch.
- Do not remove or relax the existing hard `max_load_average` gate.

### Deferred to Follow-Up Work

- Manual high-concurrency dogfood validation at `max-agents 25`: execute from the operator repository root because ticket workspaces are intentionally barred from mutating the shared test harness.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/config/schema.ex` owns embedded agent fields, numeric validation, and preservation of explicit YAML `null` for default-on load configuration.
- `src/lib/aiur/config.ex` exposes load settings with the per-scheduler contract documented beside the accessors.
- `src/lib/aiur/orchestrator.ex` performs the prewarm gate, load gate, and slot accounting in the normal new-work dispatch path; its `State` struct is the appropriate home for controller memory.
- `src/test/aiur/orchestrator_load_gate_test.exs` already tests deterministic load decisions without reading live `/proc` data.
- `src/test/aiur/workspace_and_config_test.exs` covers parsing, validation, integer-to-float casting, defaults, and explicit null behavior for load settings.

### Institutional Learnings

- `docs/brainstorms/2026-06-24-agent-synthetic-load-containment-requirements.md` distinguishes future-dispatch load protection from control of work already running.
- Issue #852 shows that the dispatch controller must account for host-wide load, including work outside the Aiur fleet, while preserving a hard safety ceiling.

### External References

- No external research is needed: the repository has established load-gate, configuration, and pure-decision test patterns that directly match this work.

---

## Key Technical Decisions

- **Keep the adaptive controller inside the orchestrator state.** It needs only per-run effective capacity and the last decrease timestamp, and should reset naturally with the daemon rather than introduce persistence or another process.
- **Apply the envelope before normal slot selection, while still evaluating the hard gate.** This makes the envelope a lower admission cap and preserves the hard gate as the absolute ceiling for sudden spikes.
- **Use 1-minute host load and explicit cooldown.** The existing source is already portable and overridable for tests; cooldown prevents repeated reductions from the same moving-average sample.
- **Expose the controller as a pure, deterministic decision helper.** Tests can inject load, scheduler count, time, prior effective capacity, and configuration without starting the full application or generating host load.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

| Observed load / state | Envelope result | Hard gate result |
|---|---|---|
| Load unavailable or envelope disabled | Preserve the current effective capacity | Fail open unless the separately configured hard gate can evaluate |
| Load at or below target | Add the configured ramp step, clamped to the static/session cap | Allow dispatch when below the hard ceiling |
| Load above target and cooldown elapsed | Apply multiplicative decrease, clamped to at least one | Still allow only when below the hard ceiling |
| Load above hard ceiling | Preserve/decrease the adaptive capacity as appropriate | Hold all new normal dispatch |

---

## Implementation Units

### U1. Add adaptive load configuration and operator documentation

**Goal:** Make target load, ramp step, and cooldown available as validated agent settings with a clear per-scheduler contract.

**Requirements:** R1, R4

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/config/schema.ex`
- Modify: `src/lib/aiur/config.ex`
- Modify: `.aiur/examples/config.example`
- Modify: `src/README.md`
- Test: `src/test/aiur/workspace_and_config_test.exs`

**Approach:** Mirror the existing default-on load-gate field, including preservation of explicit YAML null where it disables an otherwise-default setting. Validate a positive target and ramp step and a non-negative cooldown; document that target and hard threshold are per scheduler and serve different roles.

**Patterns to follow:** `agent.max_load_average` schema, accessor, explicit-null preservation, and configuration test coverage.

**Test scenarios:**
- Happy path: omitted keys produce safe defaults and integer YAML values cast to the expected numeric type.
- Edge case: explicit null disables the adaptive target without disabling the hard gate.
- Error path: zero/negative target or ramp step and negative cooldown are rejected.

**Verification:** Parsing a realistic agent block yields the documented defaults and invalid values return the existing configuration error shape.

---

### U2. Implement bounded AIMD envelope decisions

**Goal:** Track an effective normal-dispatch limit that rises under the target and decreases under overshoot, while respecting static/session caps.

**Requirements:** R2, R3, R5, R6

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: `src/test/aiur/orchestrator_load_gate_test.exs`
- Test: `src/test/aiur/orchestrator_max_agents_test.exs`

**Approach:** Add controller state and a pure transition decision that receives prior effective capacity, measured load, per-scheduler target, static/session ceiling, ramp step, cooldown, and time. Initialize conservatively, clamp every transition to the valid range, skip adjustment for unavailable load, and make high-load reduction multiplicative rather than another fixed decrement.

**Patterns to follow:** `load_gate/3`, `prewarm_gate/2`, `State`, `max_concurrent_agent_limit/1`, and the test-only pure helper pattern in `Aiur.Orchestrator`.

**Test scenarios:**
- Happy path: consecutive low-load samples increase capacity by the configured ramp step.
- Edge case: a large ramp step cannot exceed the configured/session cap.
- Edge case: high load halves/reduces capacity, observes cooldown before reducing again, and never falls below one.
- Error path: unavailable load preserves the prior effective capacity.

**Verification:** Focused controller tests cover growth, decrease, cooldown, and lower/upper clamps without accessing live host load.

---

### U3. Wire the envelope into normal dispatch admission

**Goal:** Use the controller's effective capacity for new normal work while preserving all existing safety and lifecycle rules.

**Requirements:** R2, R3, R4, R5, R6

**Dependencies:** U1, U2

**Files:**
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: `src/test/aiur/orchestrator_load_gate_test.exs`
- Test: `src/test/aiur/orchestrator_max_agents_test.exs`

**Approach:** Read load once per poll whenever either load control is enabled, update the adaptive capacity before normal choice, then retain the existing hard-gate decision. Feed the effective cap only into normal slot availability; retain current bypass behavior for retries/reactivations and never alter running entries when reducing capacity.

**Patterns to follow:** `dispatch_or_hold/2`, `maybe_choose_under_load/2`, `available_slots/1`, and the existing hard-gate logging behavior.

**Test scenarios:**
- Integration: low load permits normal dispatch until the current envelope capacity is filled, then later polls can admit more after growth.
- Integration: high load reduces future admission but leaves an over-limit running set intact to drain naturally.
- Integration: load above `max_load_average` still holds new dispatch even after the envelope transition.
- Edge case: a runtime/session cap lower than the envelope value wins immediately.

**Verification:** Orchestrator admission uses the smaller of adaptive and static/session limits, and the prior hard-gate contract remains green.

---

## System-Wide Impact

- **Interaction graph:** Configuration parsing feeds orchestrator poll-time load sampling, which updates an effective admission limit before normal issue selection.
- **Error propagation:** Missing `/proc` load data remains non-fatal; the scheduler continues with the prior envelope and the existing fail-open behavior.
- **State lifecycle risks:** Lowering effective capacity below active workers must only drain naturally, matching static-cap reduction semantics.
- **API surface parity:** Existing `max-agents` controls retain their static/session meaning; dashboards and control responses should not silently reinterpret those values as the adaptive limit.
- **Unchanged invariants:** The hard gate, state-specific caps, paused reservations, and retry/reactivation paths remain separate from the adaptive new-work limit.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| The 1-minute average reacts slowly to a burst | Keep the existing higher hard gate and make the controller conservative at startup. |
| Repeated samples produce excessive downshifts | Honor a monotonic-time cooldown and test it deterministically. |
| A runtime max-agent change leaves capacity stale | Clamp the envelope against the latest static/session limit at every admission decision. |
| Load is unavailable on a supported deployment | Preserve effective capacity and continue dispatch, matching the existing load gate's fail-open contract. |

---

## Documentation / Operational Notes

- Document `target_load_average`, ramp step, and cooldown next to `max_load_average`, including the per-scheduler multiplication and explicit-null behavior.
- The requested `max-agents 25` manual scenario must be run by an operator outside this ticket workspace; focused automated tests cover the deterministic controller contract here.

---

## Sources & References

- Related issue: #465
- Related incident: #852
- Related code: `src/lib/aiur/orchestrator.ex`
- Related tests: `src/test/aiur/orchestrator_load_gate_test.exs`
- Related configuration: `src/lib/aiur/config/schema.ex`

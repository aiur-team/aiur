---
title: "feat: Add memory admission gates"
type: feat
status: completed
date: 2026-07-11
---

# feat: Add memory admission gates

## Summary

Add an optional free-memory floor that holds normal new-work dispatch and agent-launched Mix verification while Linux `MemAvailable` is below the configured threshold, then resumes automatically when memory recovers.

---

## Problem Frame

CPU-oriented dispatch and build limits can still admit work when RAM is nearly exhausted. At high fleet concurrency, simultaneous agent and Mix process growth can therefore OOM the daemon or host before load-average controls react.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input -- un-validated bets that should be reviewed before implementation proceeds.*

- `agent.min_free_memory_mb` is optional and disabled when omitted; the repository cannot choose a safe machine-independent default.
- Unavailable or malformed host memory data fails open, matching the existing Linux-only load gate and preserving non-Linux development support.
- The dispatch check follows the existing hard-load gate's scope: normal new-work polling is held, while retry, reactivation, and explicit operator redispatch semantics remain unchanged.
- The repository has no in-tree MemAvailable sampler to reuse. A new canonical BEAM-side reader will serve dispatch and future controllers; the Bash build hook needs an equivalent minimal parser because it must remain independent of the Aiur BEAM.

---

## Requirements

- R1. Parse and validate an optional positive `agent.min_free_memory_mb` setting and expose it through runtime configuration.
- R2. Read Linux `/proc/meminfo` `MemAvailable` deterministically, without touching the source when the gate is disabled, and degrade safely when the source is unavailable.
- R3. Hold normal new-work dispatch while available memory is below the configured floor and allow a later poll to resume after recovery without changing already-running agents.
- R4. Hold agent-launched `mix compile` and `mix test` before build-slot acquisition while memory is below the same floor, then continue through the existing lease gate after recovery.
- R5. Emit always-on `aiur_perf`-style diagnostics when dispatch or a build is deferred for memory, including the observed and configured values.
- R6. Prove hold and recovery with injected memory samples and a synthetic meminfo file; retain existing load, build-slot, timeout, and stale-owner behavior.
- R7. Document configuration, disabled behavior, Linux/fail-open semantics, and operational observability in the configuration reference.

---

## Scope Boundaries

- Do not add percentage thresholds, cgroups, swap controls, per-agent RSS accounting, or adaptive multi-resource control; those belong to follow-up controller and telemetry work.
- Do not terminate or pause work that is already running when memory crosses the floor.
- Do not change Mix task recognition beyond the existing compile/test contract.
- Do not extend the existing local build gate to SSH workers; its packaged hook path and environment injection are local-only today.
- Do not claim a real saturation/OOM soak from an agent workspace; the operator must run that scenario from the allowed repository root.

### Deferred to Follow-Up Work

- Multi-resource adaptive saturation using memory, CPU, and FD headroom: issue #927.
- Daemon-side resource telemetry and durable sampling: issue #930.
- Operator-run high-concurrency saturation soak: required after focused deterministic verification because ticket workspaces cannot drive the live dogfood harness.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/system_load.ex` provides the Linux-only, injectable, fail-open resource-reader pattern.
- `src/lib/aiur/orchestrator/dispatch_policy.ex` keeps resource admission decisions pure and short-circuits disabled `/proc` reads.
- `src/lib/aiur/orchestrator/dispatcher.ex` owns the normal prewarm/load/new-work admission sequence and always-on `aiur_perf load_hold` logging.
- `src/lib/aiur/build_gate.ex` supplies environment to the BEAM-independent Bash lease hook.
- `src/priv/build_gate.bash` owns Mix queueing, slot acquisition, timeout, recovery, and exit-status preservation.
- `src/test/aiur/orchestrator_load_gate_test.exs` and `src/test/aiur/build_gate_test.exs` already establish deterministic admission and shell-hook integration patterns.

### Institutional Learnings

- `docs/plans/2026-07-09-001-refactor-load-concurrency-envelope-plan.md` preserves a hard safety gate independently from adaptive capacity and limits it to future normal dispatch.
- `docs/plans/2026-07-09-001-refactor-fleet-mix-build-gate-plan.md` requires the build gate to survive daemon/agent exits and keep ordinary agent work unblocked.
- Issue #930 confirms current resource sampling is external and ad hoc, so there is no production sampler implementation to reuse in this branch.

### External References

- No external research is needed; the repository has direct configuration, `/proc`, admission-policy, and Bash-hook patterns for this change.

---

## Key Technical Decisions

- **Use one absolute MB floor rather than adding percentage configuration.** This matches the concrete acceptance criterion and avoids introducing total-memory policy before the adaptive controller exists.
- **Sample once per normal dispatch admission cycle.** Memory joins the existing prewarm and load decisions without introducing state, timers, or a new process; a held cycle naturally retries on the next tracker poll.
- **Keep the build check before lease acquisition.** Low-memory builds do not consume scarce build slots while waiting, and recovery proceeds through the existing atomic lease path.
- **Make the shell gate active when either capacity or memory admission is configured.** An operator who disables build concurrency can still retain the memory safety floor.
- **Log continuous holds once per observed deferral transition in the Bash loop.** This makes waits visible without writing one line per second; dispatch retains the existing once-per-poll diagnostic cadence.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

| Admission surface | Memory source | Below floor | Recovered / unavailable |
|---|---|---|---|
| Normal new-work dispatch | Canonical BEAM host-memory reader | Log and return the unchanged orchestrator state | Next poll dispatches; unavailable data fails open |
| Agent Mix compile/test | Bash hook reading the same Linux field | Log and wait without claiming a build slot | Continue into the existing lease loop; unavailable data fails open |

---

## Implementation Units

### U1. Add memory configuration and host reader

**Goal:** Establish the validated operator setting and canonical BEAM-side `MemAvailable` sample used by dispatch and future resource controls.

**Requirements:** R1, R2, R6

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/system_memory.ex`
- Modify: `src/lib/aiur/config/schema/agent.ex`
- Modify: `src/lib/aiur/config.ex`
- Test: `src/test/aiur/system_memory_test.exs`
- Test: `src/test/aiur/workspace_and_config_test.exs`

**Approach:** Parse the `MemAvailable` kB field into whole MB through an injectable source, return an unavailable sentinel for missing or malformed input, and validate only positive configured floors while allowing omission to disable the feature.

**Patterns to follow:** `Aiur.SystemLoad`, the optional agent schema fields, and adjacent configuration tests.

**Test scenarios:**
- Happy path: realistic meminfo with unrelated fields yields the expected whole-MB MemAvailable value.
- Edge case: exact and fractional-MB kB values use a documented deterministic conversion.
- Error path: missing field, malformed value, wrong unit, and unreadable source return unavailable rather than raising.
- Configuration: omission yields disabled behavior, a positive integer is preserved, and zero/negative/non-integer values are rejected with the field path.

**Verification:** Runtime configuration and the reader expose a stable optional integer contract without reading live `/proc` in tests.

### U2. Gate normal dispatch on memory headroom

**Goal:** Prevent new polling waves from starting while available memory is already below the configured floor.

**Requirements:** R2, R3, R5, R6

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/orchestrator/dispatch_policy.ex`
- Modify: `src/lib/aiur/orchestrator/dispatcher.ex`
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: `src/test/aiur/orchestrator_load_gate_test.exs`

**Approach:** Add pure hold/dispatch comparison and disabled-read short-circuit helpers beside the load gate, sample memory during normal admission, and return the unchanged state with an always-on diagnostic when below the floor. Preserve prewarm ordering, adaptive load updates, and already-running entries.

**Patterns to follow:** `read_load`, `load_gate`, `maybe_choose_under_load`, and `aiur_perf load_hold`.

**Test scenarios:**
- Happy path: available memory above or exactly at the floor permits dispatch.
- Hold: memory one MB below the floor returns hold and prevents candidate selection.
- Recovery: a below-floor sample followed by an above-floor sample allows the later admission decision.
- Disabled: omitted threshold does not invoke the memory source.
- Error path: unavailable memory fails open while load admission remains independently authoritative.

**Verification:** Focused policy tests demonstrate deterministic hold/recovery and existing load-envelope tests remain green.

### U3. Gate Mix verification and document the contract

**Goal:** Make every recognized agent compile/test wait for memory recovery before competing for a fleet build lease, with deterministic integration coverage and discoverable configuration.

**Requirements:** R1, R4, R5, R6, R7

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/build_gate.ex`
- Modify: `src/priv/build_gate.bash`
- Modify: `.aiur/examples/config.example`
- Modify: `src/README.md`
- Test: `src/test/aiur/build_gate_test.exs`

**Approach:** Add the optional floor to `BuildGate.shell_env`, which already flows unchanged through the local `AgentEnvironment.workspace_env` seam. Let the hook read an overridable meminfo path and wait before slot acquisition when the sample is below the floor. Keep timeout accounting, stale-owner recovery, and real command exit status intact. Install the hook for memory-only operation even when the build-slot cap is zero.

**Execution note:** Start with the synthetic meminfo recovery integration test so the shell wait/resume contract is proven without allocating memory on the shared host.

**Patterns to follow:** Existing fake Mix/mise executables, queue-contention tasks, and hook environment construction in the build-gate tests.

**Test scenarios:**
- Hold and recovery: a compile sees a below-floor synthetic meminfo file, does not start, then starts after the file is raised above the floor.
- Boundary: memory exactly at the floor proceeds immediately.
- Integration: after memory recovery, normal slot contention still limits concurrent fake Mix processes.
- Memory-only mode: build-slot capacity zero plus a configured floor still installs the hook and gates compile/test.
- Disabled: no floor preserves current build-gate behavior and avoids reading meminfo.
- Error path: unreadable/malformed meminfo fails open; a memory wait still observes the existing overall timeout and never runs Mix after timeout.
- Observability: the defer line uses the stable `aiur_perf` prefix and includes available/floor values without per-second log spam.

**Verification:** The shell integration tests prove commands stay stopped below the synthetic floor and resume through the unchanged lease/release path after recovery; docs explain how operators enable and observe the gate.

---

## System-Wide Impact

- **Interaction graph:** Agent config feeds both orchestrator admission and child shell environment; the two runtime boundaries independently observe the same host field.
- **Error propagation:** Resource-source failures remain non-fatal and fail open; build-slot timeout continues to return its established command failure.
- **State lifecycle risks:** Dispatch holds mutate no running/claimed state, and build memory waits own no lease that could become stale.
- **API surface parity:** Both supported coding-agent backends inherit the hook for local work through `Aiur.AgentEnvironment`; the pre-existing SSH path does not export the build hook and remains out of scope.
- **Integration coverage:** Synthetic source changes prove recovery on both the pure dispatch decision and real Bash wait loop.
- **Unchanged invariants:** Load admission, adaptive capacity, prewarm fallback, build-slot ownership, stale-owner recovery, Mix task recognition, and running-agent lifecycle remain independent.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| Check-then-start races allow several processes to observe the same recovered sample | Build-slot capacity remains the second bound; document the floor as a minimum admission threshold and cover ordered memory-before-slot behavior. |
| No portable `MemAvailable` equivalent exists on macOS | Fail open when `/proc/meminfo` is absent, matching the load gate's existing portability contract. |
| Bash and BEAM parsers drift | Pin both to the single `MemAvailable` kB field and identical boundary fixtures; keep parsing intentionally narrow. |
| Memory waits consume build slots or leave stale state | Perform the check before lease acquisition and write no slot owner until memory admission succeeds. |
| A machine-specific default either blocks healthy hosts or provides false safety | Leave the setting opt-in and document explicit operator sizing. |

---

## Documentation / Operational Notes

- Describe `min_free_memory_mb` beside the load and build controls, including that omission disables it and equality is admitted.
- Use `aiur_perf memory_hold surface=dispatch` and `surface=build` style diagnostics for stable operational search.
- A real saturation soak remains an operator-root validation step; focused tests must not allocate synthetic RAM in the shared workspace.

---

## Sources & References

- Origin issue: #926
- Related build gate: #881
- Related adaptive controller: #927
- Related telemetry work: #930
- Related code: `src/lib/aiur/system_load.ex`, `src/lib/aiur/orchestrator/dispatch_policy.ex`, `src/lib/aiur/build_gate.ex`, `src/priv/build_gate.bash`

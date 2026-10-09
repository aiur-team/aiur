---
title: BQ-G5 capacity for optimistic dependent start - Plan
date: 2026-10-09
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
epic: aiur-team/aiur#3755
area: G5 capacity
code_base: main at 0e5b8d0de
---

# BQ-G5 capacity for optimistic dependent start - Plan

## Goal Capsule

- Objective: keep every safe slot busy, give scarce slots to fully-ready work first, and reach the safe fleet size quickly after a restart or a max-agents raise, without overloading the host or re-creating the #3659 oscillation.
- Product authority: Kevin (operator intent in epic #3755). This brainstorm ran unattended; the Executor decided in-the-weeds choices, recorded under Key Decisions.
- Open blockers: G5-1 needs G1's start-trigger classifier (see Seams). G5-2 and G5-3 have no blocker.

## Product Contract

### Summary

Three changes. G5-1 orders dispatch in three tiers (ready, then optimistic by critical path, then held) and caps the share of slots that optimistic work may hold. G5-2 remembers the last demonstrated safe fleet size across restarts and climbs back to it with the existing bounded fast ramp instead of +1 per sample. G5-3 wakes the dispatch tick when the operator raises max-agents, so the raise acts on the next floor-allowed cycle, not up to one full poll interval later.

### Problem Frame

Today the dispatch order (`DispatchCandidates.order/2`, #3693) has two tiers: candidates without a cached dependency hold, then held candidates. Inside a tier it sorts by build-queue downstream rank, priority label, position, age and id (`DispatchPolicy.sort_issues_for_dispatch/1`). When G1 lets a dependent start before its blocker merges, a third kind of candidate appears. Without a rule, optimistic work competes with ready work on equal terms. On this host that matters: slots are scarce. The 2026-10-09 12:13Z run held 1-11 of 16 slots with load 24-55 on 16 cores (alerts.ndjson of run 20261009T121316Z). The host load, not the configured cap, is the real limit.

The AIMD envelope starts at 1 on every boot (`DispatchPolicy.initial_load_envelope_limit/1`). Since #3528 the first fresh sample only completes bootstrap, and later below-target samples add `load_ramp_step` (default 1). Samples arrive once per dispatch cycle: 120 s base, 240 s with the webhook widen factor. Reaching 16 takes 15 samples, about 30-60 minutes. #1465/#1506 once seeded the cold start from CPU headroom; #3521 showed that seed jumping to 12 agents on a stale sample overloaded the host, and #3528 removed it. Nothing remembers the size the host proved it can carry.

A max-agents raise does add agents automatically. The new static limit applies at once (`Slots.apply_session_max_concurrent_agents/2`), and the next dispatch cycle sees free slots. But the raise does not wake the tick (removed in #2137 when polls ran inline), and the envelope above the old cap climbs +1 per sample. Raising 16 to 24 with ready work takes 8 samples, 16-32 minutes.

### Key Decisions

- Ready work always beats optimistic work. A ready ticket of any priority dispatches before an optimistic ticket. Operator intent: "fully-ready first". Optimistic work fills slots that ready work cannot use.
- Optimistic means "the blocker's code is not on the base branch yet". A dependent whose blockers are all merged (issue still open within the grace window) is ready. This keeps the default trigger (`pr_merged`) from producing optimistic work at all.
- Critical path is the longest chain of open dependents below a ticket, then the dependent count. A long chain gates the finish time more than a wide fan-out. The graph comes from build-queue hints when a queue is adopted, else from the native `blocked_by` edges in the polled issue set (the live run has no adopted queue). No GitHub I/O is added.
- The ready tier keeps today's order unchanged. Re-sorting ready work by critical path is a separate behavior change with its own risk; not in scope.
- The optimistic share cap is a fraction of the effective (envelope) limit, default 0.5, with a floor of one slot when the share is above zero. A share of 0 disables optimistic dispatch. The cap counts runners that are optimistic now (blocker still unmerged), so a runner whose blocker merges frees optimistic share without a restart.
- No preemption. When ready work appears while optimistic runners hold the slots, nothing is paused or killed; ready work takes the next free slot. Killing in-progress work wastes more than it saves.
- Optimistic work takes the same admission path as all new work: max-agents, the AIMD envelope, the hard load gate, the run-queue gate, memory, file descriptors, the build gate, `Aiur.BackgroundCpu` discounting. No bypass.
- The persisted value is a demonstrated safe level: the occupied slot count held for five consecutive fresh samples with no sustained overload. A permitted-but-unused envelope proves nothing, so it is not recorded. A sustained-overload decrease lowers the record to the reduced envelope.
- The boot keeps #3528's invariants. The envelope still starts at 1, the first fresh sample still does not widen, and only fresh below-target samples widen. The change is the widening shape: below the remembered level it uses the existing bounded fast ramp (double, at most +3 per sample), above it the additive step.
- The record expires after 6 hours and is ignored when the scheduler count changed. A stale record is old evidence about a different load mix.
- Above the remembered level, fast probing is allowed only while the fresh gate signal is under half the target. This answers #3659's "faster increase while load is well under the threshold" without touching the sustained-overload decrease from #3663.
- G5-3 wakes the tick with `Lifecycle.wake_tick/1`, which respects the GitHub poll floor and only moves a scheduled tick earlier. Poll reads now run as tracker tasks, so the #2137 inline-poll wedge does not return.

### Requirements

**Dispatch tiers and optimistic share (G5-1)**

- R1. Dispatch evaluates candidates in three tiers: ready, optimistic, held. Within the ready and held tiers the order is today's order.
- R2. Within the optimistic tier, candidates sort by critical-path depth (descending), then open-dependent count (descending), then today's order.
- R3. An optimistic candidate is skipped with a visible decline reason (`optimistic_share`) when current optimistic occupancy is at the cap.
- R4. The cap is `max(1, floor(share x effective_limit))` for share above 0, and 0 for share 0. The share is a config value with default 0.5.
- R5. Optimistic occupancy counts active and reserved-paused runners whose blocker code is still not on the base branch, re-evaluated each cycle from polled state.
- R6. Each runner records how it started (`ready` or `optimistic`) for telemetry and for G2/G4.
- R7. Status and the waiting reason show the optimistic share in use (for example `optimistic 2/4`) and name the cap when it holds a candidate.

**Envelope resume (G5-2)**

- R8. The daemon records the demonstrated safe level durably and updates it on change only.
- R9. On boot, a valid record (age at most 6 h, same scheduler count) sets a resume level of `min(record, static limit)`.
- R10. While the envelope is under the resume level, each fresh below-target sample widens with the existing fast-ramp shape. At or above it, widening is additive, except fast while the gate signal is under half the target.
- R11. Stale, unavailable or above-target samples never widen. The sustained-overload decrease, the hard gate and the batch stale-sample stop stay as they are.
- R12. Status shows the resume level and its age while the envelope is below it, so a ramp reads as a ramp.

**Max-agents raise (G5-3)**

- R13. Raising max-agents (set or adjust) wakes the dispatch tick, bounded by the GitHub poll floor. Lowering does not wake it.
- R14. The control call still returns at once; it never runs a poll inline.

### Acceptance Examples

- AE1. 3 ready and 5 optimistic candidates, 4 free slots, share 0.5 of effective 8: the 3 ready tickets and 1 optimistic ticket (the deepest chain) dispatch.
- AE2. Optimistic runners at cap, a blocker merges: on the next cycle that runner counts as ready and one more optimistic candidate may start.
- AE3. Share 0: no optimistic candidate dispatches; every one shows `optimistic_share`.
- AE4. Record 7, cap 16, below-target fresh samples: envelope 1, 1 (bootstrap), 2, 4, 7, then +1 per sample. Today: 1, 1, 2, 3, 4, 5, 6, 7.
- AE5. Same boot with a frozen load sample: the envelope stays at 1 (the #3521 test still passes).
- AE6. The #3659 spiky trace (two-sample bursts over target, mean under it) with a lagged per-agent load model: no more halvings than on main, and the envelope reaches the record within 6 fresh samples.
- AE7. Record 9 hours old: envelope ramps as today.
- AE8. Running 16 of 16 with ready work, `set max-agents 24`: the next dispatch cycle starts within the GitHub floor, not a full interval later.

### Scope Boundaries

- No change to when a dependent becomes eligible (G1), the agent's behavior while optimistic (G2), restacking or merge order (G3), or abandoned-blocker policy and waste metrics (G4).
- No change to the hard load gate, the sustained-overload rule (#3663), the niced-work discount (#3624), or the stale-sample batch stop (#3528).
- No re-sort of the ready tier by critical path.
- No preemption of running optimistic agents.

### Seams with other areas

- G1 (assumed interface): a pure classifier over cached blocker state, `classify(issue, terminal_states, trigger) :: :ready | {:optimistic, blockers} | {:held, blockers}`, used by dispatch's dependency gate. G5-1 calls it in `DispatchCandidates.order/2` and for occupancy. G5-1 is blocked by the G1 ticket that adds it.
- G2: G5-1 stamps `start_mode` on the running entry at dispatch. G2's dispatch-time subscription may read it. If G2 lands a marker first, G5-1 reuses it.
- G4: waste metrics key on `start_mode`; the share cap is the lever G4's policy may tune.
- G3: none.

### Outstanding Questions

Open questions for Kevin:

- Default optimistic share: 0.5 of effective slots? Recommended: yes; raise later from G4's waste data.
- Should an optimistic ticket on a long critical path ever outrank a ready leaf ticket? Recommended: no, ready first as stated; revisit with G4 data.

Findings for the Executor, not questions:

- On this host the binding limit is per-agent load (load 40-55 at 5-7 agents on 16 cores), not the ramp. G5-2 shortens restarts; it does not raise the steady state. The larger lever is per-agent build load (`mix_scheduler_cap`, `max_concurrent_builds`).

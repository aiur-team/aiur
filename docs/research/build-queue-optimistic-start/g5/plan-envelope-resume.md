---
title: Resume the dispatch envelope near the last safe level - Plan
date: 2026-10-09
type: feat
ticket: BQ-G5-2
priority: 3
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g5/brainstorm.md
execution: code
code_base: main at 0e5b8d0de
---

# Resume the dispatch envelope near the last safe level - Plan

## Goal Capsule

- Objective: after a restart or a max-agents raise, reach the fleet size the host has proved it can carry in a few fresh samples instead of one slot per sample, without the #3521 overload and without the #3659 oscillation.
- Product authority: brainstorm R8-R12, AE4-AE7 (Product Contract unchanged).
- Open blockers: none. Independent of G1-G4.

---

## Problem Frame

The AIMD envelope (`DispatchPolicy.update_load_envelope/7`, `src/lib/aiur/orchestrator/dispatch_policy.ex`) starts at 1 (`initial_load_envelope_limit/1`, set in `src/lib/aiur/orchestrator/lifecycle.ex`). The first fresh sample only marks bootstrap complete (the `load_envelope_state(1, nil, load, %{bootstrap_complete?: false})` clause, #3528). Then each fresh below-target sample adds `agent.load_ramp_step` (default 1). The bounded fast ramp (`fast_ramp/3`: `min(effective * 2, effective + 3)`) runs only after a decrease (`fast_recovery?/2` needs `last_decrease_ms`). Samples come once per dispatch cycle, 120-240 s. Reaching 16 takes 15 samples, 30-60 minutes.

History constrains the fix. #1465/#1506 seeded the cold start from CPU headroom. #3521 then showed 12 dispatches in 10 minutes on a 4-6 minute stale sample, load 86 on 16 cores; #3528 removed the seed and made freshness mandatory. #3659/#3663 stopped spike-driven halving by requiring three consecutive overloaded samples. The fix must keep all of these.

---

## Planning Contract

### Requirements trace

R8 record (U1, U2). R9 boot seed (U3). R10 widening shape (U3). R11 invariants (U3 tests). R12 status (U4).

### Key Technical Decisions

- KTD1. Record a demonstrated level, not a permitted one. Safe level = `Slots.used_slots/1` when it held for 5 consecutive fresh samples with `overload_samples < 3` on each (the `SustainedLoad` streak). An unused envelope proves nothing about load.
- KTD2. Lower the record on every sustained-overload decrease to the reduced envelope. The record tracks recent truth in both directions.
- KTD3. Keep #3528's boot invariant exactly: start at 1; the first fresh sample does not widen; only fresh below-target samples widen; the batch stale-sample stop (`DispatchBatch`) is untouched.
- KTD4. Below the resume level, widen with the existing `fast_ramp/3` shape; no new step constant. 1, 2, 4, 7, 10, 13, 16 reaches 16 in 6 widening samples, and each step at most +3 limits the load lag from agents that have not started compiling yet.
- KTD5. Above the resume level, widen additively, except fast while the fresh gate signal (`SystemLoad.gate_signal/3`, which already applies the `Aiur.BackgroundCpu` discount) is under half of `target * schedulers`. This is #3659's suggested faster increase, isolated from the decrease rule.
- KTD6. Record lifetime 6 hours, invalid when `System.schedulers_online/0` differs, ignored when `target_load_average` is null. Config: `agent.load_resume_max_age_seconds` default 21600; 0 disables resume.
- KTD7. Persist with the `GlobalPauseStore` pattern (`Aiur.JsonStore` under `Aiur.Config.Paths.decision_state_dir/0`), file `dispatch-envelope.json`, version 1. Write on change only, at most once per 60 s, from the Orchestrator after the sample (a few hundred bytes; the write is atomic via JsonStore). A read failure means no resume, never a hold.
- KTD8. A max-agents raise needs no special case: the envelope keeps its value, the static limit rises, and KTD4/KTD5 decide the next steps. If the host proved a higher level earlier (record above the old cap), the raise climbs fast up to it.

### High-Level Technical Design

Widening decision per fresh sample (directional):

```text
fresh sample?  no -> keep (unchanged)
bootstrap pending and effective == 1 -> keep, mark bootstrap complete (unchanged)
gate_signal > target*schedulers -> SustainedLoad.decrease (unchanged); lower record (KTD2)
effective < resume_level            -> min(resume_level, fast_ramp(effective))
gate_signal < 0.5*target*schedulers -> fast_ramp(effective)
otherwise                           -> effective + ramp_step
all results capped at static_limit
```

---

## Implementation Units

### U1. Envelope store

**Goal:** load and save the safe-level record.
**Requirements:** R8, R9.
**Dependencies:** none.
**Files:** new `src/lib/aiur/orchestrator/envelope_store.ex`, test `src/test/aiur/orchestrator/envelope_store_test.exs`.
**Patterns to follow:** `src/lib/aiur/orchestrator/global_pause_store.ex` (path resolution, `JsonStore`, normalize, version).
**Approach:** record `{version, safe_level, schedulers, recorded_at (UTC)}`. `load/1` takes now and the current scheduler count and returns `{:ok, level} | :none`.
**Test scenarios:** round-trip; missing file is `:none`; corrupt JSON is `:none` with a warning; age over limit is `:none`; scheduler mismatch is `:none`; max age 0 is `:none`; level below 1 rejected.
**Verification:** tests pass with `:decision_state_dir` pointed at a tmp dir.

### U2. Track the demonstrated level

**Goal:** maintain the safe level in `load_envelope_state` and persist changes.
**Requirements:** R8; brainstorm KTD on demonstrated level.
**Dependencies:** U1.
**Files:** `src/lib/aiur/orchestrator/dispatch_policy.ex` (`update_load_envelope/7`), `src/lib/aiur/orchestrator/state.ex` (`load_envelope_state` type: `safe_level`, `safe_streak`, `resume_level`, `persisted_at_ms`), `src/lib/aiur/orchestrator/dispatcher.ex` (persist after `update_load_envelope` in `maybe_choose_under_load/4`, fresh samples only), tests `src/test/aiur/orchestrator/dispatch_policy_test.exs`, `src/test/aiur/orchestrator/sustained_load_test.exs`.
**Approach:** keep the pure policy pure: it returns the new state; the dispatcher does the write. Streak counts fresh samples where occupancy stayed at or above the candidate level and the overload streak stayed below 3; reused samples neither advance nor reset it (same rule as #3663).
**Test scenarios:** 5 fresh calm samples at occupancy 6 record 6; 4 samples do not; a sustained decrease from 8 to 4 lowers the record to 4; a reused sample does not advance the streak; occupancy dropping (agents finishing) does not lower the record; no write when unchanged; write throttled to 60 s.
**Verification:** unit tests; file appears in a fixture run.

### U3. Seeded widening

**Goal:** apply the resume level at boot and the KTD4/KTD5 widening shape.
**Requirements:** R9, R10, R11; AE4, AE5, AE6, AE7.
**Dependencies:** U1, U2.
**Files:** `src/lib/aiur/orchestrator/lifecycle.ex` (load record at init into `load_envelope_state.resume_level`), `src/lib/aiur/orchestrator/dispatch_policy.ex` (`adjust_load_envelope/4`, `adjust_load_envelope_without_headroom/4`, `envelope_options` type), `src/lib/aiur/config/schema/agent.ex` and `src/lib/aiur/config.ex` (`load_resume_max_age_seconds`), tests `src/test/aiur/orchestrator/dispatch_policy_test.exs`, `src/test/aiur/orchestrator_load_gate_test.exs`, `src/test/aiur/orchestrator/dispatcher_test.exs`, new simulation `src/test/aiur/orchestrator/envelope_resume_simulation_test.exs`.
**Approach:** resume level = `min(record, static_limit)`; it never raises the envelope by itself, it only selects the step shape. Starting value stays 1.
**Execution note:** write the AE5 frozen-sample test and the AE6 simulation first; they guard the two historical failures.
**Test scenarios:**
- Covers AE4. Record 7, cap 16, below-target fresh samples: 1, 1, 2, 4, 7, 8.
- Covers AE5. Same with a frozen sample: stays 1; the #3528 frozen-sample and already-stale boot tests still pass unchanged.
- Covers AE6. Simulation: per-agent load 8 arriving 2 samples after dispatch, plus #3659 two-sample bursts; count halvings over 120 samples on main and with the change; the change has no more, and reaches the record within 6 widening samples.
- Covers AE7. Record 9 h old: 1, 1, 2, 3, 4.
- Above-target sample below the resume level: no widening.
- Gate signal at 40% of target above the resume level: fast step; at 60%: +ramp_step.
- Raise 16 -> 24 with record 20: fast to 20, then additive.
- `target_load_average: null`: static limit, record ignored.
**Verification:** mutation check reverts the seeded branch and AE4/AE6 fail.

### U4. Status shows the resume

**Goal:** make a ramp read as a ramp.
**Requirements:** R12.
**Dependencies:** U3.
**Files:** `src/lib/aiur/orchestrator/slots.ex` (`max_concurrent_agent_status/1` adds `resume_level`, `resume_recorded_ago_seconds`), `src/lib/aiur/orchestrator/status_report.ex`, `src/lib/aiur/orchestrator/capacity_binding.ex` (envelope label), tests `src/test/aiur/orchestrator/status_report_test.exs`, `src/test/aiur/orchestrator/slots_test.exs`.
**Approach:** while effective < resume level: `AIMD envelope 4 -> 7 (resuming, safe level from 12m ago)`. Emit `system.fleet.capacity.resume_seeded` once at boot with the level and age.
**Test scenarios:** status map fields; label text while resuming and after; event emitted once.
**Verification:** fixture `aiurdev status` shows the label.

---

## Verification Contract

- Focused tests above pass with `mix test --max-cases 4`; the AE4/AE6 tests fail with the U3 production hunk reverted; all #3528 and #3663 tests pass unchanged.
- Compile with warnings as errors, format, lint, config-docs and docs-prose checks.
- Post-deploy (Executor): restart the daemon with ready work; record minutes from boot to the pre-restart occupancy, before (main) and after. Count `system.fleet.capacity.backoff` per hour for one hour before and after at similar load; healthy is no increase.

## Definition of Done

U1-U4 merged; `website/docs-app/reference/configuration.md` rows for `agent.target_load_average` (startup text), `agent.load_ramp_step` and new `agent.load_resume_max_age_seconds` updated; `src/examples/workflows/*.yaml` unchanged unless they set the agent keys; CI green on the head SHA.

---

## Risks

| Risk | Mitigation |
|---|---|
| Overshoot from load lag (agents compile minutes after dispatch) re-creates #3521 | Freshness unchanged; steps capped at +3; ceiling is a level held 5 samples without sustained overload. |
| Record from a lighter workload (docs tickets) seeds too high for a heavy one (compile-bound) | Sustained-overload decrease still halves and lowers the record (KTD2); 6 h expiry. |
| Faster probing above the record re-creates #3659 | Only under half target; simulation AE6 counts halvings against main. |
| State file shared by two daemons on one host | Path is instance- and project-qualified (`decision_state_dir/0`). |

## Rollout

On by default (`load_resume_max_age_seconds: 21600`); set 0 to restore today's ramp. First boot after deploy has no record and behaves as today.

## Findings for the Executor

On this host the steady state is bound by per-agent load (load 40-55 with 5-7 agents on 16 cores, run 20261009T121316Z). This plan shortens recovery to that level; it does not raise it.

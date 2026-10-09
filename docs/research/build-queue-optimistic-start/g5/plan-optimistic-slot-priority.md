---
title: Prefer ready work over optimistic starts and cap the optimistic share - Plan
date: 2026-10-09
type: feat
ticket: BQ-G5-1
priority: 2
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g5/brainstorm.md
execution: code
code_base: main at 0e5b8d0de
---

# Prefer ready work over optimistic starts and cap the optimistic share - Plan

## Goal Capsule

- Objective: when slots are short, dispatch fully-ready work first, then optimistic work by critical path, and never let optimistic work hold more than a configured share of the effective slots.
- Product authority: brainstorm R1-R7, AE1-AE3 (Product Contract unchanged).
- Open blockers: G1's start-trigger classifier (the ticket that makes dispatch's `blocked_by` gate follow `start_trigger`). Without it there is no optimistic candidate to order.

---

## Problem Frame

`Aiur.Orchestrator.DispatchCandidates.order/2` (`src/lib/aiur/orchestrator/dispatch_candidates.ex`) sorts with `DispatchPolicy.sort_issues_for_dispatch/1` and moves candidates with a cached dependency hold to the end (#3693). Once G1 lets a dependent start while its blocker's PR is open, a third class exists. Without a rule, optimistic tickets take scarce slots on equal terms with ready work. On this host the effective envelope was 1-11 of 16 for most of 2026-10-09, so the order matters more than the cap.

---

## Planning Contract

### Requirements trace

R1-R3 tiers and decline (U2, U3). R4 cap formula and config (U1, U3). R5 dynamic occupancy (U3). R6 start mode on the runner (U4). R7 status (U5).

### Key Technical Decisions

- KTD1. Tier comes from G1's classifier, not a second copy of the rule. Assumed interface: `classify(issue, terminal_states, trigger) :: :ready | {:optimistic, blockers} | {:held, blockers}`, pure, over cached blocker state (`Tracker.cached_blocked_by/1` for GitHub). If G1 names it differently, adapt the call sites only.
- KTD2. A blocker whose PR is merged counts as ready even if its issue is still open (brainstorm Key Decision). Optimistic means "blocker code not on the base branch".
- KTD3. Critical path = longest chain of open dependents below the candidate. Source order: build-queue edges when a queue is adopted (extend `Aiur.BuildQueue.Ordering` with a depth function beside `downstream_open/2` and publish it in the hints row), else native `blocked_by` edges over `state.last_polled_issues`. Pure, cycle-safe (visited set), no GitHub I/O.
- KTD4. The cap check lives in the dispatch decision, after the existing gates, as decline reason `:optimistic_share`. It sits next to `:state_capacity` and `:worker_capacity` in `dispatch_unheld_state_decision/4`, so manual resume and the decline list stay consistent (#2699 test enumerates reasons).
- KTD5. Cap = `max(1, floor(share * Slots.effective_concurrent_agent_limit(state)))` for share > 0, else 0. Occupancy = active plus reserved-paused runners classified optimistic now (same accounting as `Slots.used_slots/1`).
- KTD6. Config key `build_queue.optimistic_slot_share`, float 0.0..1.0, default 0.5. It is fleet-wide because slots are fleet-wide. G1's per-queue trigger decides whether a ticket can be optimistic; this key decides how many may run.
- KTD7. No preemption and no admission bypass. All candidates still go through `Dispatcher.maybe_choose_under_load/4`, `Slots.available_slots/1`, the hard load gate, run-queue, memory, FD, build and provider gates, and the `Aiur.BackgroundCpu` discount.

### Seams

- G1: provides KTD1's classifier and the trigger setting. This ticket is blocked by that G1 ticket.
- G2: reads `start_mode` from the running entry (U4) to subscribe the dependent at dispatch. If G2 lands a marker first, reuse it.
- G4: keys waste metrics on `start_mode`.

---

## Implementation Units

### U1. Config key for the optimistic share

**Goal:** add `build_queue.optimistic_slot_share`.
**Requirements:** R4.
**Dependencies:** none.
**Files:** `src/lib/aiur/config/schema/build_queue.ex`, `src/lib/aiur/config.ex` (accessor), `src/test/aiur/configuration_reference_test.exs` if it lists keys, `src/examples/workflows/*.yaml` only if they list build_queue keys, `website/docs-app/reference/configuration.md` (build_queue table), `src/test/aiur/config/build_queue_test.exs`.
**Approach:** float field, default 0.5, `validate_number` 0.0..1.0. Config-docs check must pass (paragraph rule ≤360 chars).
**Test scenarios:** default is 0.5; 0 and 1 accepted; -0.1 and 1.5 rejected; YAML `null` rejected or defaulted per the schema's existing `empty_values: []` rule.
**Verification:** `mix aiur.config.docs`-style check (whatever CI runs for config docs) passes.

### U2. Critical-path depth

**Goal:** a pure depth function and its two sources.
**Requirements:** R2.
**Dependencies:** none.
**Files:** `src/lib/aiur/build_queue/ordering.ex`, `src/lib/aiur/build_queue/hints.ex` and the hints writer in `src/lib/aiur/build_queue/server.ex` (add depth to the row; keep `sort_key/1` and `held?/1` stable), new `src/lib/aiur/orchestrator/critical_path.ex` for the native-edge fallback, tests `src/test/aiur/build_queue/ordering_test.exs`, `src/test/aiur/orchestrator/critical_path_test.exs`.
**Approach:** depth(node) = 0 for no open dependents, else 1 + max depth of open dependents. Memoize per call. Cycles terminate via a visited set and count as depth 0 past the repeat. Native fallback builds edges from each polled issue's `blocked_by` entries (blocker id -> dependent id), open dependents only.
**Test scenarios:** chain A->B->C gives depths 2,1,0; fan-out A->{B,C,D} gives depth 1 and count 3; diamond counts once; cycle A->B->A terminates; closed dependents excluded; hints row without depth (old table) reads depth 0.
**Verification:** pure tests pass; hints table readers unchanged.

### U3. Three-tier order and the share cap

**Goal:** order ready, optimistic, held; decline optimistic candidates over the cap.
**Requirements:** R1, R2, R3, R4, R5; AE1, AE2, AE3.
**Dependencies:** U1, U2, G1 classifier.
**Files:** `src/lib/aiur/orchestrator/dispatch_candidates.ex`, `src/lib/aiur/orchestrator/dispatch_policy.ex` (decline reason list, type, `dispatch_unheld_state_decision/4`), `src/lib/aiur/orchestrator/slots.ex` (optimistic occupancy and cap helpers), `src/lib/aiur/orchestrator/pause_resume.ex` (decline translation for manual resume), tests `src/test/aiur/orchestrator/dispatch_candidates_test.exs`, `src/test/aiur/orchestrator/dispatch_policy_test.exs`, `src/test/aiur/orchestrator/slots_test.exs`.
**Approach:** `order/2` keeps `sort_issues_for_dispatch/1` as the base order, then a stable split into three lists. The optimistic list re-sorts by `{-depth, -downstream, base index}`. The cap check needs current occupancy; compute it from `state.running` entries classified with the same classifier against the entry's latest polled issue (`state.last_polled_issues`), falling back to the stamped `start_mode` when the issue is not in the snapshot. A dispatch within the same batch updates `state.running`, so the next candidate sees the new count.
**Patterns to follow:** #3693's stable partition and its 60-held/3-eligible test in `dispatch_candidates_test.exs`.
**Test scenarios:**
- Covers AE1. 3 ready + 5 optimistic, 4 free, effective 8, share 0.5: dispatches 3 ready, then the deepest optimistic; the other 4 decline `:optimistic_share`.
- Covers AE2. Runner at cap whose blocker merges between cycles: occupancy drops by one; one more optimistic dispatches.
- Covers AE3. Share 0: every optimistic candidate declines; ready ones dispatch.
- Priority does not cross tiers: a priority:1 optimistic waits behind a priority:4 ready.
- Effective limit 1 and share 0.5: cap is 1, not 0.
- Held candidates still order last and still decline `:dependency`.
- `DispatchPolicy.dispatch_decline_reasons/0` includes `:optimistic_share` and the resume translation covers it (the #2699 enumeration test).
**Verification:** the listed tests fail on main and pass with the change (mutation check: revert the split and the cap).

### U4. Start mode on the runner

**Goal:** record how each runner started.
**Requirements:** R6.
**Dependencies:** U3.
**Files:** `src/lib/aiur/orchestrator/dispatcher.ex` (running entry map near the `running_entry =` literal; keep through `inherit_redispatch_safety/2`), `src/lib/aiur/orchestrator/state.ex` (type), test in `src/test/aiur/orchestrator/dispatcher_test.exs`.
**Approach:** `start_mode: :ready | :optimistic` from the classifier at dispatch. A redispatch of the same ticket re-classifies. Emit it on the existing dispatch telemetry event.
**Test scenarios:** optimistic dispatch stamps `:optimistic`; ready stamps `:ready`; a retry after the blocker merged stamps `:ready`.
**Verification:** telemetry line carries the field.

### U5. Status and waiting reason

**Goal:** show the share and name the cap when it holds work.
**Requirements:** R7.
**Dependencies:** U3.
**Files:** `src/lib/aiur/orchestrator/slots.ex` (`max_concurrent_agent_status/1` gains `optimistic: %{running, cap, share}`), `src/lib/aiur/orchestrator/status_report.ex`, `src/lib/aiur/orchestrator/waiting_reason.ex`, `src/lib/aiur/orchestrator/capacity_binding.ex` if the cap should name a binding, tests `src/test/aiur/orchestrator/status_report_test.exs`, `src/test/aiur/orchestrator_status_test.exs`.
**Approach:** status line `optimistic 2/4`; a ticket declined by the cap shows "waiting: optimistic share full (2/4)". Starvation alerts must not count optimistic-share declines as capacity starvation while ready work dispatches.
**Test scenarios:** status map contains the counts; waiting reason text for `:optimistic_share`; `capacity_starved` does not fire when the only undispatched work is optimistic-capped.
**Verification:** `aiurdev status` shows the counts in a fixture run.

---

## Verification Contract

- Focused tests for U1-U5 pass with `mix test --max-cases 4`; each new behavior test fails with its production hunk reverted.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`, lint, config-docs and docs-prose checks pass.
- Post-deploy (Executor): with G1's optimistic trigger on a test queue, `aiurdev status` shows `optimistic n/cap`, ready tickets start before optimistic ones in the dispatcher log, and the cap holds.

## Definition of Done

U1-U5 merged; docs updated (`website/docs-app/reference/configuration.md` build_queue table; `website/docs-app/concepts/build-orders.md` "Queueing a Build Order" gains one paragraph on dispatch tiers and the share); CI green on the head SHA.

---

## Risks

| Risk | Mitigation |
|---|---|
| Classifier needs blocker PR state that is not cached, so every candidate costs I/O | KTD1 requires the cached path; if G1's classifier needs I/O, order by cached state and let the dispatch-time gate stay authoritative (same split #3693 made). |
| Depth over 300+ polled issues each cycle | Memoized O(V+E); measure in the dispatcher log; skip recomputation when the polled set is unchanged. |
| Optimistic share counted against a tiny effective limit blocks all optimistic work during the ramp | Floor of 1 when share > 0. |
| New decline reason breaks `aiur resume` translation | U3 test enumerates reasons (#2699 pattern). |

## Rollout

Default share 0.5 has no effect until G1's trigger produces optimistic candidates (the default `pr_merged` produces none, KTD2). No flag beyond the share; share 0 disables optimistic dispatch.

## Deferred to Follow-Up Work

- Re-sorting the ready tier by critical path.
- Tuning the default share from G4's waste data.

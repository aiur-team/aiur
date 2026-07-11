---
title: "refactor: Characterize orchestrator residual glue"
type: refactor
status: completed
date: 2026-07-10
origin: docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md
---

# refactor: Characterize orchestrator residual glue

## Summary

Add focused, test-only characterization around the residual orchestrator facade
before its helpers move: CI lifecycle coordination, worker control-status writes,
and monitor `:DOWN` routing. Exercise the facade's existing public/test seams so
the follow-up relocation can change ownership without changing behavior.

---

## Problem Frame

The first decomposition round moved most logic out of `Aiur.Orchestrator`, but
the remaining glue still coordinates several stateful modules inside one
GenServer process. Existing coverage is broad but scattered, leaving the exact
facade contracts difficult to preserve mechanically during FF-W1.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below
are agent inferences that fill gaps in the input and should remain visible during
implementation and review.*

- Add focused test files instead of moving or deleting existing regression
  coverage; overlapping assertions are retained when they protect different
  integration boundaries.
- Drive only existing `handle_info/2` and `*_for_test` seams. Production helpers
  and visibility remain unchanged in this test-only wave.
- Prefer deterministic state/message assertions over elapsed sleeps or process
  teardown, keeping the tests safe under the shared four-case test cap.

---

## Requirements

- R1. Characterize pending/pass/fail CI lifecycle coordination, including
  transition-before-control/event ordering and transition-failure fail-closed
  behavior.
- R2. Characterize control-status writes for real transitions, idempotent
  confirmations, pause-clock updates, and unknown running entries.
- R3. Characterize monitor routing for stale refs, normal completion, and crash
  retry paths, including claim retention, retry metadata, session accounting,
  and the absence of teardown.
- R4. Make no production behavior or facade relocation change.
- R5. Preserve the single-process, token-guarded timer, teardown-ordering, and
  pause/resume-clock invariants from
  `docs/refactor/research-arch/giant-orchestrator.md` section 4.

**Origin actors:** A3 (executor agents), A4 (Aiur loop pipeline)

**Origin flows:** F2 (behavior-preserving ticket execution)

---

## Scope Boundaries

- No helper relocation, new `CiLifecycle` module, or control-state abstraction.
- No changes to retry policy, CI policy, tracker behavior, alerts, or dashboard
  rendering.
- No expansion into the other round-one characterization gaps (main-push,
  pending auto-resume, thrash, token payloads, PR-anchor cleanup, command scan,
  or connectivity normalization).
- No manual TUI run: this wave changes only headless characterization tests, and
  agent workspaces are prohibited from launching `aiurdev --test`.

### Deferred to Follow-Up Work

- FF-W1 owns the actual CI, control-status, and `:DOWN` helper relocation after
  these pins land.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/orchestrator.ex` owns the residual CI coordinator,
  `transition_control_status/4`, `handle_worker_control_state/4`, and
  `handle_agent_down/2`.
- `src/test/aiur/orchestrator_deactivate_test.exs` covers the wider CI feature,
  but does not directly pin a live runner's pending-to-pause transition or a
  failed tracker write's side-effect boundary.
- `src/test/aiur/regression/orchestrator_dispatch_retry_test.exs` pins retry
  policy and the primary normal/crash outcomes; the new facade-focused tests
  should add routing and ownership assertions rather than repeat the delay table.
- `src/test/aiur/orchestrator_status_test.exs` and
  `src/test/aiur/alerts_test.exs` establish control-message and clock patterns.
- `src/test/aiur/orchestrator/pause_resume_test.exs` covers the extracted pure
  writer but not the facade transition coordinator.

### Institutional Learnings

- The refactor safety plan requires characterization-first changes, no
  `Process.sleep` synchronization, bounded receives, and isolated global state.
- Existing regression files intentionally remain stable through extraction;
  focused facade contract files give FF-W1 a smaller verification target.

---

## Key Technical Decisions

- Test the observable coordinator boundary rather than private helpers: this
  permits pure ownership moves while pinning state and side-effect order.
- Keep CI and control/monitor characterization separate: CI needs tracker and
  event isolation, while the latter can use direct state/message calls with no
  external store.
- Cancel retry timers created by direct `:DOWN` characterization so the tests do
  not leak delayed messages into later cases.

---

## Implementation Units

### U1. Pin CI lifecycle coordination

**Goal:** Give the net-new CI feedback loop a dedicated facade-level contract.

**Requirements:** R1, R4, R5

**Dependencies:** None

**Files:**
- Create: `src/test/aiur/orchestrator_ci_lifecycle_test.exs`

**Approach:**
- Use an injected tracker client and the existing CI poll test seam to observe
  label writes, live-runner control messages, persisted head state, and event
  publication without real GitHub traffic.
- Isolate the approval store and event subscriptions per test.

**Execution note:** Add characterization coverage without changing production
code; each assertion should describe current behavior that FF-W1 must preserve.

**Patterns to follow:**
- CI setup and injected pollers in
  `src/test/aiur/orchestrator_deactivate_test.exs`.
- Event cleanup in `src/test/aiur/events/event_delivery_test.exs`.

**Test scenarios:**
- Integration: pending CI on a live human-review runner writes `ci-wait` before
  sending pause control, retains the claim, refreshes the issue, and stamps the
  CI pause clock/reason.
- Error path: a failed pending-state tracker write leaves the runner working and
  emits no pause control or terminal CI event.
- Integration: a passed `ci-wait` head writes human-review, remembers the
  approved head, refreshes the running issue, and publishes one `ci.passed`
  event for that head.
- Edge case: a pending observation for an existing `ci-wait` ticket is an
  idempotent no-op.

**Verification:**
- CI coordinator behavior is readable from one focused test file and survives
  replay/failure without premature control or event side effects.

---

### U2. Pin control-status and monitor routing

**Goal:** Lock the state mutations that FF-W1 will move into their owning modules.

**Requirements:** R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Create: `src/test/aiur/orchestrator_control_routing_test.exs`

**Approach:**
- Exercise synchronous facade transitions and direct `handle_info/2` routing on
  minimal `%Orchestrator.State{}` fixtures.
- Assert complete state ownership effects around the running entry, claim,
  completion set, retry entry, and aggregate runtime totals.

**Execution note:** Characterize the whole normal-vs-crash `:DOWN` branch as an
atomic contract; do not introduce a helper seam just for the test.

**Patterns to follow:**
- Minimal running entries in
  `src/test/aiur/regression/orchestrator_dispatch_retry_test.exs`.
- Pause-clock assertions in `src/test/aiur/orchestrator_status_test.exs`.

**Test scenarios:**
- Happy path: working-to-paused control transition preserves capabilities,
  stores the supplied pause attribution, and freezes the runtime clock.
- Edge case: an already-paused confirmation and an unknown issue are exact
  no-ops, so duplicate worker confirmations cannot restart the pause clock.
- Happy path: a working worker confirmation thaws the clock without disturbing
  unrelated entry data.
- Edge case: `:DOWN` with an unknown monitor ref returns the original state.
- Integration: normal `:DOWN` removes only the running entry, records session
  runtime, marks completion, keeps the claim, and schedules continuation attempt
  one with host/workspace metadata.
- Error path: abnormal `:DOWN` removes only the running entry, records runtime,
  does not mark completion, keeps the claim, and schedules the next failure
  attempt with the original routing metadata.

**Verification:**
- The direct facade tests distinguish no-op, normal, and crash routes and show
  that `handle_agent_down/2` performs no teardown.

---

### U3. Run the scoped characterization gate

**Goal:** Prove the test-only change is formatted, warning-free, and stable with
the directly related orchestrator suites.

**Requirements:** R4, R5

**Dependencies:** U1, U2

**Files:**
- Test: `src/test/aiur/orchestrator_ci_lifecycle_test.exs`
- Test: `src/test/aiur/orchestrator_control_routing_test.exs`
- Test: `src/test/aiur/orchestrator_deactivate_test.exs`
- Test: `src/test/aiur/regression/orchestrator_dispatch_retry_test.exs`
- Test: `src/test/aiur/orchestrator_status_test.exs`

**Approach:**
- Run the two focused files first, then the directly related existing files with
  the required four-case concurrency cap; run compile, format check, and scoped
  strict lint on the changed test files.

**Test scenarios:**
- Integration: all new and directly related characterization suites pass in the
  same invocation without leaking timers, event subscriptions, or application
  environment.

**Verification:**
- The scoped local pre-PR gate passes with no production diff.

---

## System-Wide Impact

- **Interaction graph:** Tests cover tracker observation to GenServer state,
  control message, retry timer, and persisted event boundaries.
- **Error propagation:** Tracker failures remain fail-closed; monitor failures
  remain retryable without releasing claims prematurely.
- **State lifecycle risks:** Duplicate CI observations, duplicate worker
  confirmations, and stale monitor refs are pinned as idempotent/no-op paths.
- **Integration coverage:** The tests call the facade paths that FF-W1 will
  delegate, rather than only testing extracted pure functions.
- **Unchanged invariants:** All code still executes in the orchestrator process;
  token guards, teardown order, and pause/resume clock sequencing are untouched.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| New tests duplicate broad existing coverage | Target missing ordering, idempotence, ownership, and failure assertions; keep the files small and concern-specific. |
| Direct retry scheduling leaks timer messages | Cancel each captured timer immediately after asserting its token and metadata. |
| Global tracker/event configuration makes tests flaky | Restore application environment, isolate approval-store paths, and unsubscribe/stop stores in `on_exit`. |
| Characterization accidentally blesses an incidental implementation detail | Assert externally meaningful state and ordering required by the named refactor invariants, not helper names or log wording. |

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md`
- Ticket wave plan: `docs/refactor/research-arch/orchestrator-facade-finish.md`
- Behavior invariants: `docs/refactor/research-arch/giant-orchestrator.md`
- CI design: `docs/plans/2026-07-09-001-feat-ci-feedback-loop-plan.md`
- Related implementation: #892
- Originating ticket: #941

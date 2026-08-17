---
title: "fix: Bound and monitor decision dispatch"
created_at: 2026-08-16
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Bound and Monitor Decision Dispatch

## Goal Capsule

- **Objective:** Ensure every accepted Decision dispatch reaches one durable terminal edge while bounding cross-decision work and preserving admission order for each ticket.
- **Authority:** Issue #1058 and the existing DecisionStore persist-before-notify lifecycle are authoritative.
- **Stop conditions:** Do not weaken dispatch correlation, retry fences, queue reconciliation, or durable failure attention.
- **Tail ownership:** Implementation includes worker supervision, backpressure and ordering tests, scoped validation, PR self-review, and CI handoff.

## Product Contract

### Requirements

- **R1. Supervised work:** Dispatch callbacks run under the application task supervisor and are monitored by a durable coordinator rather than started as unowned tasks.
- **R2. Bounded concurrency:** At most a configured, finite number of dispatch jobs run across decisions; excess accepted work waits only while bounded global and per-ticket queue capacity remains, after which admission fails synchronously and settles durably.
- **R3. Keyed ordering:** Jobs for one ticket retain admission order while independent tickets may run concurrently.
- **R4. Exact settlement:** Result, timeout, abnormal exit, and late-result races produce at most one terminal callback to DecisionStore; stale callbacks cannot clear or settle a newer attempt.
- **R5. Durable recovery:** Timeout, worker exit, coordinator restart, supervisor/start failure, and saturation settle through the existing durable failed event and attention path so explicit retry remains available.
- **R6. Visibility:** Queue saturation emits one coalesced global attention until capacity recovers, while each rejected action records its existing action-scoped failure attention. Repeated rejections do not repeat the global alert.

### Acceptance Examples

- **AE1:** A hung dispatch times out, its worker is terminated, the action records one failed attempt, and explicit retry can dispatch again.
- **AE2:** An externally killed dispatch worker records one failed attempt without killing the coordinator or wedging the action.
- **AE3:** A worker result arriving after timeout is ignored and cannot add a second event or affect a retry.
- **AE4:** With the concurrency limit occupied, independent jobs remain queued and running workers never exceed the limit.
- **AE5:** Multiple decisions for the same ticket start in admission order; another ticket can use available capacity independently.

## Planning Contract

### Key Technical Decisions

- **KTD1 — Dedicated keyed coordinator.** Add a small `Aiur.DecisionDispatchTasks` GenServer modeled on `Aiur.CoordinationTasks`. It owns FIFO keyed queues, active task monitors, timeouts, global and per-ticket admission limits, and exact terminal callbacks while DecisionStore remains the only lifecycle writer.
- **KTD2 — Ticket is the ordering key.** A ticket is the destination lane consumed by the Orchestrator; serializing all its Decision actions prevents later answers from overtaking earlier ones while allowing distinct tickets to dispatch concurrently.
- **KTD3 — One correlated terminal callback.** The coordinator removes an active task before notifying DecisionStore and ignores subsequent result/DOWN/timeout messages. Task-start failure is immediately terminal rather than retried indefinitely. Admission uses a non-expiring local call so it cannot report an indeterminate timeout and then run late. DecisionStore additionally matches the active attempt ID before clearing in-flight state or appending lifecycle evidence.
- **KTD4 — Coordinator restart recovery.** DecisionStore monitors the named coordinator. If it restarts after accepting active or queued jobs, DecisionStore clears and durably fails every correlated in-flight attempt before remonitoring the replacement, so lost in-memory coordinator state cannot wedge a decision.
- **KTD5 — Durable failure plus coalesced saturation.** Operational failures normalize to explicit dispatch failure classes and use `settle_dispatch_failure/5`, preserving current action-scoped attention, retry, audit, and replay behavior. The coordinator separately latches one global saturation/recovery attention pair so fleet pressure is visible without a per-rejection global alert storm.

### Scope Boundaries

- Revision follow-up background tasks are not Decision delivery dispatches and remain outside this ticket.
- No new operator-facing config key is introduced; conservative coordinator limits remain code defaults with test-only start options.
- This is an internal reliability fix and does not require user documentation changes.

### Sources & Research

- `src/lib/aiur/decision_store.ex` owns dispatch fences, durable settlement, retry, and failure attention.
- `src/lib/aiur/coordination_tasks.ex` is the repository pattern for bounded keyed FIFO work, supervised task monitors, timeouts, and exact-once completion.
- `src/lib/aiur.ex` starts `Aiur.TaskSupervisor` before DecisionStore and defines the required supervision order.
- `src/test/aiur/decision_store_test.exs` contains the answer-outbox concurrency, replay, retry, and persistence coverage to extend.
- No `docs/solutions/` institutional-learning corpus exists in this checkout. External research was skipped because local OTP and lifecycle contracts determine the design.

## Implementation Units

### U1. Add the bounded monitored dispatch coordinator

- **Requirements:** R1-R3, R6
- **Files:** `src/lib/aiur/decision_dispatch_tasks.ex`, `src/lib/aiur.ex`, `src/test/aiur/decision_dispatch_tasks_test.exs`, `src/test/aiur/application_test.exs`
- **Approach:** Implement bounded global and per-ticket admission, FIFO runnable tickets, one active job per ticket, supervised monitored tasks, per-job timers, exact-once completion, and immediate terminal callback on task-start failure.
- **Test Scenarios:** maximum concurrency, same-ticket order, independent-ticket parallelism, hot-ticket capacity reservation, hang timeout, abnormal exit, late result, bounded admission, task-start failure, and coordinator survival.

### U2. Route DecisionStore dispatch through the coordinator

- **Requirements:** R4-R6
- **Files:** `src/lib/aiur/decision_store.ex`, `src/test/aiur/decision_store_test.exs`, `src/test/aiur/decision_delivery_integration_test.exs`
- **Dependencies:** U1
- **Approach:** Monitor the coordinator, enqueue correlated jobs by ticket through non-expiring local admission, record active attempt identity only after acceptance, settle synchronous admission failures durably, durably fail all accepted attempts on coordinator restart, accept only matching terminal callbacks, then drain superseding work as today.
- **Test Scenarios:** dispatcher timeout, killed worker, duplicate/late terminal callback, saturation failure plus retry, coordinator restart with active and queued work, max concurrency across decisions, and ordered same-ticket decisions.

## Verification Contract

| Gate | Command / evidence | Covers |
|---|---|---|
| Compile | `cd src && mise exec -- mix compile --warnings-as-errors` | U1-U2 |
| Format | `cd src && mise exec -- mix format --check-formatted` | U1-U2 |
| Deterministic scope | `cd src && mise exec -- mix aiur.affected_tests` | U1-U2 |
| Affected tests | Run every emitted test command with `mix test --max-cases 4` | U1-U2 |

## Definition of Done

- AE1-AE5 execute against the real coordinator/store wiring and fail against the former unmonitored implementation.
- Every task terminal race settles once, releases its ticket lane and global slot, and leaves the store writable.
- Operational failures persist auditable reason classes and preserve explicit retry.
- Compile, formatting, and all affected tests pass before draft PR handoff.

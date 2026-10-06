---
ticket_id: MP-R2-C1-T04
feature_id: MP-R2
chunk_id: MP-R2-C1
bucket: 1 (refactor)
title: Pin bus supervision order and re-bind after an Exchange restart
status: ready
blocked_by: [DESIGN-R2 §1]
prior_units: [U3, U9]
prior_boundaries: [BUS #10, K #1, EXE #26]
prior_features: []
prior_findings: []
size_owner: n/a (test-only; aiur.ex 610 lines is APP_BOOT, not touched)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C1-T04 — Supervision order and Exchange-crash re-bind (plan AC4)

## Identity and outcome

- **Bucket 1, MP-R2, C1, T04.**
- **Value.** Packaging (C2–C4) and the exporter (C6-T02) must keep the start order
  and the `:rest_for_one` cascade the bus relies on. This ticket makes both
  executable assertions.
- **Deliverable.** New `describe` block in `src/test/aiur/application_test.exs`
  (order) and a new file `src/test/aiur/events/exchange_restart_rebind_test.exs`
  (PROPOSED) for the cascade.
- **Non-goals.** Killing the shared application's `Aiur.Events.Exchange` in a test
  (it would restart Orchestrator and DecisionStore for the whole suite). No
  production change.

## Dependencies and blockers

- DESIGN-R2 §1. Concurrent with other C1 tickets.
- `application_test.exs` is shared; other open PRs may add tests to it. Add a new
  `describe` block at the end to keep the diff appendable.

## Verified starting point (45a290e3)

- The application supervisor uses `:rest_for_one` (`src/lib/aiur.ex:116-119`).
- Child order: `Aiur.Events.IdGenerator` (`aiur.ex:358`), `{Aiur.Events.Exchange,
  name: Aiur.Events.Exchange}` (`:359`), `Aiur.Events.Publisher` (`:374`),
  `Aiur.DecisionStore` (`:407`), subscription registry and supervisor (`:415-416`),
  `Aiur.TicketActivity` (`:429`), `Aiur.BuildOrder.TicketHistoryProvider` (`:433`),
  `Aiur.Orchestrator` (`:442`), recording children `[Claims, ExecutorWakeInbox,
  ExecutorListener]` (`:463,503`), `Aiur.AllowedContributors` last when recording
  (`:476-480`). `DecisionMetrics` at `:409`.
- `AiurApp.child_specs/1` (`aiur.ex:244`) and the `modules/1` helper
  (`src/test/aiur/application_test.exs:137-143`) let tests assert order without
  starting anything (examples at `:322-344`).
- `Exchange` supports a non-default name with its own ETS table key
  (`events/exchange.ex:57-58,130-142,184-193`); `subscribe/2` and `publish/3` take
  the server name (`:70,93`).
- Existing re-bind evidence for the real listener: deleting its rows from the
  Exchange table and sending `:resubscribe` (`src/test/aiur/executor_listener_test.exs:97-131`).

## Chosen design

1. **Static order test** (both run shapes used at `application_test.exs:323-326`):
   index(IdGenerator) < index(Exchange) < index(Publisher) < index(each of
   DecisionStore, SubscriptionStoreSupervisor, TicketActivity,
   TicketHistoryProvider, DecisionMetrics, Orchestrator, ExecutorListener). Also
   assert ExecutorListener follows ExecutorWakeInbox and Claims.
2. **Cascade test** in an isolated tree: start
   `Aiur.start_supervisor([{Aiur.Events.Exchange, name: ExchangeT}, {Probe, exchange: ExchangeT, pattern: "ticket.*.#"}], name: SupT)`
   where `Probe` is a test-local GenServer that subscribes in `init/1` through
   `Exchange.subscribe(pattern, ExchangeT)` and forwards `{:event, e}` to the test.
   Kill `ExchangeT` with `Process.exit(pid, :kill)`; wait for the new Exchange pid
   via a monitor and `Supervisor.which_children/1`; assert the Probe has a new pid
   and `Exchange.bindings_for(new_probe, ExchangeT) == ["ticket.*.#"]`; publish and
   `assert_receive`.
3. **Real listener re-bind** is already covered by `executor_listener_test.exs:97`;
   this ticket cites it and does not duplicate it.

## Implementation steps

1. Append `describe "event bus start order"` to `application_test.exs` with test
   "bus core precedes every Exchange subscriber in both run shapes".
2. Create `exchange_restart_rebind_test.exs` with the `Probe` module defined inside
   the test module; use `start_supervised!` for the isolated tree so it is torn
   down; no global names.
3. Comment both: "Guards existing behaviour for C2–C6 moves; deliberately green on main."

## Non-happy paths

- Restart intensity: one kill stays within default `max_restarts`.
- Run-shape gaps: when `recording?` is false the recording children are absent
  (`aiur.ex:503-504`); the order test skips the listener assertion only when it is
  absent from the spec list, and asserts presence in the default shapes as
  `application_test.exs:174` already does.
- Exporter (C6-T02) will add a child: C6-T02 must extend this order test (exporter
  after Publisher, and placed at the end of the always-on block).

## Compatibility and rollout

n/a — test-only.

## Verification

Tests:

- `application_test.exs` `"bus core precedes every Exchange subscriber in both run shapes"`.
- `exchange_restart_rebind_test.exs` `"a subscriber after the Exchange re-binds after the Exchange is killed"`.
- `exchange_restart_rebind_test.exs` `"events published before the restart are not redelivered to the new subscriber"` (documents loss across restart; `live` class).

```bash
env -C <worktree>/src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= \
  mise exec -- mix test test/aiur/application_test.exs test/aiur/events/exchange_restart_rebind_test.exs
```

Mutation check: swap `aiur.ex:358` and `:374` (Publisher before IdGenerator) in a
worktree; the order test must fail. Change `aiur.ex:118` `:rest_for_one` to
`:one_for_one` and run the cascade test against `Aiur.start_supervisor/2`; the
re-bind assertion must fail (probe keeps the old pid and has no binding). Record
commands and `git status --porcelain`.

## Completion and handoff

- [ ] Three tests green on main; both mutations fail them.
- Docs: none.
- Dependents: C4-T03 (acceptance), C6-T02 (extends the order test for the exporter).

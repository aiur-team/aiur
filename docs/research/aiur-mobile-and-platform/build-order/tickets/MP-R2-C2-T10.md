---
ticket_id: MP-R2-C2-T10
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Aiur.Events facade migration batch C (commands, Executor, alerts, projections, agent runner)
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C2-T08]
prior_units: [U3, U4, U6, U7, U8]
prior_boundaries: [BUS #10, DEC #27, EXE #26, PRJ #28, RUN #18, BO #30, TEL, signal port #11]
prior_features: []
prior_findings: []
size_owner: DECISIONS (decision_store.ex 4826), EVENTS (executor_events.ex 525, alerts.ex 746); others < 500 at base. Re-check per RC-23; no file may grow.
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T10 — Facade migration, batch C

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.** No user-visible change.
- **Deliverable:** the remaining production callers outside the bus use
  `Aiur.Events` (C2-T08) instead of `Publisher`, `Exchange`, `IdGenerator`
  or `Topic`. After this batch, `git grep` finds no direct reference to
  those four modules outside `src/lib/aiur/events/` and `src/lib/aiur.ex`
  (supervision children stay as they are).
- **Non-goals:** no logic change; no move of any caller.

## Dependencies and blockers

- DESIGN-R2 §1; C2-T08.
- **Prior-unit overlap:** U3 (Executor claims/wake inbox files), U4
  (`agent_runner/`), U6 (`decision_store.ex`) may have open PRs. Each edit
  here is an alias swap; rebase on them. If a U-unit PR is in review on
  `decision_store.ex` or `executor_events.ex`, split those two files into a
  follow-up PR rather than conflict.

## Verified starting point (45a290e3)

| File | Line(s) | Call today |
| --- | --- | --- |
| `src/lib/aiur/alerts.ex` | 307 | `Publisher.publish(topic, payload, …)` |
| `src/lib/aiur/decision_store.ex` | 62 (alias), 581, 2420, 2558, 4608 | `&IdGenerator.reserve_durable_id/0`, `IdGenerator.reserve_durable_id()`, `Publisher.publish_persisted/4` ×2 |
| `src/lib/aiur/executor_events.ex` | 70, 73, 127, 483, 503, 513, 518 | `IdGenerator.reserve_durable_id/0`, `Publisher.publish_persisted/4`, `&Exchange.subscribe/1`, `IdGenerator.peek/0`, `Topic.matches?/2` ×2, `Exchange.unsubscribe/1` |
| `src/lib/aiur/executor_listener.ex` | 103, 116, 266 (+ `Topic.matches?` at 172) | `&Exchange.unsubscribe/1`, `Exchange.subscribe/1`, `Exchange.bindings_for/1` |
| `src/lib/aiur/executor_bindings.ex` | 4 (alias), `Topic.matches?` use | `Topic.matches?/2` |
| `src/lib/aiur/decision_metrics.ex` | 64 | `&Exchange.subscribe/1` |
| `src/lib/aiur/run_telemetry/writer.ex` | 27 (alias), 412 | `&Exchange.subscribe/1` |
| `src/lib/aiur/ticket_activity.ex` | 73 | default `fn -> Exchange.subscribe("ticket.*.#") end` |
| `src/lib/aiur/build_order/ticket_history_provider_options.ex` | 37 | default `fn -> Exchange.subscribe("ticket.*.#") end` |
| `src/lib/aiur/agent_runner/tool_executor.ex` | 94 | default `&Publisher.publish/3` |
| `src/lib/aiur/agent_runner/comment_context.ex` | 294 | `IdGenerator.next_id()` |
| `src/lib/aiur/agent_runner/bootstrap_digest.ex` | (one `Topic.matches?` use) | `Topic.matches?/2` |

Census command (re-run at start; line numbers drift):

```text
git grep -nE "(Publisher\.publish(_persisted)?|Exchange\.(publish|subscribe|unsubscribe|bindings_for)|IdGenerator\.(next_id|peek|reserve_durable_id)|Topic\.matches\?)\(|&(Publisher|Exchange|IdGenerator|Topic)\." -- src/lib ':!src/lib/aiur/events/'
```

Tests that drive each site: `decision_store_test.exs`, `executor_events_test.exs`,
`executor_listener_test.exs`, `executor_wake_inbox_test.exs`,
`decision_metrics*` tests, `ticket_activity` tests,
`build_order/ticket_history_provider*` tests, `agent_runner/*` tests,
`alerts*` tests, `run_telemetry/*` tests.

## Chosen design

Alias swap and prefix rename only (rule from C2-T08). `ExecutorBindings` and
`BootstrapDigest` use `Aiur.Events.matches?/2`.

## Implementation steps

1. Re-run the census; edit every hit in the table.
2. `make lint` (warnings as errors catches unused aliases).
3. Add a guard test so the migration cannot regress (below).

## Non-happy paths

None added (delegation).

## Compatibility and rollout

None. Rollback: revert.

## Verification

1. `test/aiur/events/facade_usage_test.exs` (PROPOSED)
   `"no production module outside the bus calls bus internals directly"` —
   source scan of `src/lib/**/*.ex` excluding `src/lib/aiur/events/**`,
   `src/lib/aiur/events.ex` and `src/lib/aiur.ex`, docs and comments stripped
   (reuse the C1-T06 helper), asserting no reference to
   `Aiur.Events.Publisher`, `Aiur.Events.Exchange`, `Aiur.Events.IdGenerator`
   or `Aiur.Events.Topic`. **Fails at base and before steps 1 of T08/T09/T10
   are all merged**; passes after. This is the mutation-proof guard for
   all three batches (revert any one call site → it fails naming the file).
   C4-T03 later replaces it with the checker's "component-private" rule.
2. Existing suites listed above unchanged and green.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/facade_usage_test.exs test/aiur/decision_store_test.exs \
  test/aiur/executor_events_test.exs test/aiur/executor_listener_test.exs \
  test/aiur/executor_wake_inbox_test.exs test/aiur/agent_runner/ test/aiur/build_order/
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check: restore one call site (e.g. `alerts.ex:307` back to
`Publisher.publish`) in a clean worktree → test 1 fails naming `alerts.ex`;
revert → passes.

## Completion and handoff

- [ ] Census command returns no hits outside `events/` and `aiur.ex`.
- [ ] Test 1 green; `decision_store.ex`, `executor_events.ex`, `alerts.ex` did not grow.
- [ ] Docs: none.
- Dependents: C4-T01, C4-T03 (private-module rule), C3-T02 (`publish_journaled/3` lands on the facade).

---
ticket_id: MP-R2-C2-T04
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Route Webhooks.EventSource's default publish through the Publisher boundary (RQ-6)
status: ready
blocked_by: [DESIGN-R2 §1]
prior_units: [U7]
prior_boundaries: [BUS #10, ING #9]
prior_features: []
prior_findings: [MP-R2 F12]
size_owner: n/a (event_source.ex 59 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T04 — `Webhooks.EventSource` through the Publisher

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.** No user-visible change.
- **Deliverable:** the only direct `Exchange.publish/2` outside the bus
  core is removed; `EventSource.publish/2`'s default branch calls
  `Aiur.Events.Publisher.publish/3` (switched to the `Aiur.Events` facade by
  C2-T08 later).
- **Why not delete (RQ-6 answered):** the module has **no production
  caller**. `for_transport/1` and the `Polling`/`Webhook` implementations are
  reached only from `src/test/support/webhook_mode_contract.exs:85,100-108`,
  which always injects `:publish_fun`, so the default branch
  (`event_source.ex:52-55`) is unreachable in production and tests.
  Deleting the module would delete the webhook-mode consumer contract
  harness used by `test/aiur/webhooks/consumer_equivalence_test.exs` and
  `webhook_mode_contract_test.exs` (its moduledoc,
  `webhook_mode_contract.exs:16-18`, names a `webhook_consumer_contract_test.exs`
  enforcer that does not exist at `45a290e3`), which is a test-suite and
  product decision for U7 (proved cuts), not a refactor.
  Routing the default through the Publisher removes the bypass (an event
  without an id that `SubscriptionStore` would drop as malformed,
  `subscription_store.ex:397-400`) and the bus edge, at no risk.
- **Non-goals:** no change to the harness or the `Polling`/`Webhook` modules.

## Dependencies and blockers

DESIGN-R2 §1. Fully concurrent with all other C2 tickets.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Default branch `Exchange.publish(topic, payload)` | `src/lib/aiur/webhooks/event_source.ex:21,50-58` |
| Callback + `for_transport/1` | `event_source.ex:36-41`; `event_source/polling.ex:16`, `event_source/webhook.ex:23` call `EventSource.publish/2` |
| No production caller of `for_transport/1` / `Polling` / `Webhook` | `git grep -nE "EventSource\.(Polling|Webhook|for_transport)" 45a290e3 -- src/lib` returns only the moduledoc and definitions |
| Harness always injects `:publish_fun` | `src/test/support/webhook_mode_contract.exs:100-108` |
| `Publisher.publish/3` assigns an id and returns `{:ok, id, n} | :filtered | :deduped | {:error, _}` | `src/lib/aiur/events/publisher.ex:111-122` |

## Chosen design

```elixir
_default -> Aiur.Events.Publisher.publish(topic, payload, [])
```

The return of `EventSource.publish/2` stays `{:ok, event}` (the callback
type, `event_source.ex:36,50`); the Publisher outcome is discarded exactly
as the Exchange subscriber count is discarded today. Publisher gates with
empty opts: `issue_number: nil` → tracked (`publisher.ex:497`), no actor,
no dedup key, no resource → it publishes.

## Implementation steps

1. Edit `event_source.ex:21` (alias) and `:54`.
2. Moduledoc: one sentence "the default sink is the Publisher boundary".
3. No C1-T06 row exists (`event_source.ex` is not a member); test 1 is the guard.

## Non-happy paths

- **Publisher not running:** `IdGenerator.next_id/0` exits; today
  `Exchange.publish` with no table would raise. Both crash the caller; no
  production caller exists. Unchanged risk class.
- **Durable decision topic passed:** Publisher returns
  `{:error, :decision_requires_durable_publish}`; EventSource still returns
  `{:ok, event}`. Acceptable for an unreachable path; documented.

## Compatibility and rollout

None. Rollback: revert.

## Verification

1. `src/test/aiur/webhooks/event_source_default_sink_test.exs` (PROPOSED)
   `"default sink publishes through the Publisher with an event id"` —
   `Exchange.subscribe("ticket.977.pr.opened")` in the test process; call
   `EventSource.publish(%{topic: "ticket.977.pr.opened", payload: %{number: 977}}, [])`;
   `assert_receive {:event, %{id: id, topic: "ticket.977.pr.opened", ticket_observation: _}}`
   with `is_integer(id)`. **Fails without step 1** (today the delivered map
   has no `:id` and no `:ticket_observation`).
2. Existing `webhooks/consumer_equivalence_test.exs`,
   `webhooks/webhook_mode_contract_test.exs` unchanged and green.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/webhooks/event_source_default_sink_test.exs \
  test/aiur/webhooks/consumer_equivalence_test.exs test/aiur/webhooks/webhook_mode_contract_test.exs \
  test/aiur/events/bus_boundary_test.exs
```

Mutation check: revert `event_source.ex` only → test 1 fails at the `id`
match; restore → passes.

## Completion and handoff

- [ ] No `Aiur.Events.Exchange` reference in `webhooks/`.
- [ ] Test 1 added and mutation-checked.
- [ ] Docs: none.
- Hand-off note to U7: whether `Webhooks.EventSource` and its harness should
  be cut is a U7 "proved duplicate path" question; record it there, not here.
- Dependents: C2-T08 (switches the call to the facade).

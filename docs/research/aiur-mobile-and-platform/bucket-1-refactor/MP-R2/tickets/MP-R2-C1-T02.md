---
ticket_id: MP-R2-C1-T02
feature_id: MP-R2
chunk_id: MP-R2-C1
bucket: 1 (refactor)
title: Witness whether an out-of-order lower event id is dropped by per-ticket and Executor consumers
status: ready
blocked_by: [DESIGN-R2 §1]
prior_units: [U3]
prior_boundaries: [BUS #10, EXE #26]
prior_features: []
prior_findings: [events-webhooks-executor-01 (related, distinct)]
size_owner: n/a (test-only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C1-T02 — Out-of-order id witness (RQ-2)

## Identity and outcome

- **Bucket 1, MP-R2, C1, T02.**
- **Value.** Contract O-1/O-2 says ids are not a delivery order. This ticket turns
  the source-reachable hypothesis (plan F2) into a recorded behaviour witness and
  hands the result to prior unit U3. It does not fix anything (contract O-4).
- **Deliverable.** `src/test/aiur/events/out_of_order_id_witness_test.exs`
  (PROPOSED) plus a one-paragraph finding in the PR body addressed to the U3
  event-delivery owner.
- **Non-goals.** No reorder window, no sequencer, no production change.

## Dependencies and blockers

- DESIGN-R2 §1.
- Runs concurrently with every other C1 ticket.
- **Coordination with U3:** the U3 event-delivery ticket (finding
  `events-webhooks-executor-01`, boundary note
  `docs/research/refactor-2026-09-26/synthesis/u3-worker-boundary-current-main-2026-09-30.md`)
  edits `subscription_store.ex`. This ticket only adds a test file, so there is no
  file conflict. If U3 lands first, run the witness against U3's head and report
  whether the drop still occurs.

## Verified starting point (45a290e3)

- `IdGenerator.next_id/0` is a `GenServer.call` (`events/id_generator.ex:82-85`);
  `Publisher.do_publish/3` takes the id, then calls `Exchange.publish/3` in the
  caller (`events/publisher.ex:220-224`); `Exchange.publish/3` is a plain `send/2`
  per matching binding in the caller's process (`events/exchange.ex:93-108`). Two
  publishers can therefore deliver id N+1 before N.
- `SubscriptionStore.handle_info({:event, _})` drops `event_id <= cursor`
  (`events/subscription_store.ex:394-400`); the cursor advances to `max` on success
  (`:516-521`).
- `ExecutorListener.matching_fresh_event?/2` drops `executor.*` events with
  `id <= watermark` (`executor_listener.ex:169-178`); non-`executor.*` events have no
  id gate. The watermark advances only for `executor.*` (`:149-153`).
- Test seams that already exist: `SubscriptionStore.set_enqueue_fn/1`
  (`subscription_store.ex:255-261`); temp `runtime_state_dir` setup
  (`src/test/aiur/events/subscription_store_test.exs:8-44`); listener start helper
  and named instance (`src/test/aiur/executor_listener_test.exs:13-43`).

## Chosen design

Reproduce the interleaving deterministically with no production hook:

1. Two `Task`s each call `IdGenerator.next_id()`; the test orders them so task A
   gets `low` and task B gets `high` (`high > low`). A barrier (`send`/`receive`)
   makes B deliver first.
2. B then A call `Exchange.publish(topic, %{id: id, topic: topic, ...})` (the exact
   step `do_publish/3` performs after id assignment).
3. Observe each consumer.

| Consumer | Topic | Expected today (witness) |
| --- | --- | --- |
| `SubscriptionStore` for ticket N (enqueue fn records ids) | `ticket.N.pr.review_comment` (bound via `add_subscription/3`) | enqueue sees `[high]` only; `low` dropped; cursor `high` |
| `ExecutorListener` (test name) | `executor.custom.witness` (published as raw Exchange event with `"id"`) | `low` dropped as stale; watermark `high` |
| `ExecutorListener` | `ticket.N.pr.opened` (wake path) | both delivered to the wake inbox (no id gate) |

The test asserts the **observed** behaviour so it is green on main, and names it a
witness. If it shows the drop, the PR body records: "id `low` lost by
SubscriptionStore and ExecutorListener under publisher interleaving; owner U3 /
Bucket 2 per contract O-4".

## Implementation steps

1. New module `Aiur.Events.OutOfOrderIdWitnessTest`, `async: false`.
2. Setup: copy the temp-dir setup from `subscription_store_test.exs:8-44`;
   `SubscriptionStore.set_enqueue_fn(fn id, ev -> send(test_pid, {:enqueued, id, ev.id}); :ok end)`
   and reset it to `nil` in `on_exit`.
3. Attach a store for `"witness-#{n}"`, `add_subscription/3` the ticket topic.
4. Run the two-task interleave; barrier with `:sys.get_state(store_pid)`.
5. Assert `assert_received {:enqueued, _, ^high}` and `refute_received {:enqueued, _, ^low}`;
   assert snapshot cursor `== high`.
6. Listener part: start `ExecutorWakeInbox` (`debounce_ms: 10`) and the listener
   with `patterns: ["executor.#", "ticket.*.pr.opened"], reconcile?: false`
   (options at `executor_listener.ex:45-62`); repeat the interleave for both topics;
   barrier `:sys.get_state(listener)`; assert watermark from `:sys.get_state` and
   inbox contents via `ExecutorWakeInbox.wait/1`.
7. Comment block: "Witness, deliberately green on main. Not a fix and not change
   coverage. A fix belongs to U3 (contract O-4)."

## Non-happy paths

- Flakiness: no sleeps; ordering is controlled by message barriers, and
  `:sys.get_state` is the mailbox barrier.
- Global state: unsubscribe all test bindings in `on_exit`
  (`executor_listener_test.exs:34`); never reset the global IdGenerator.
- Watermark file lives under the TestSupport log root, never `~/.aiur`.

## Compatibility and rollout

n/a — test-only.

## Verification

Tests:

- `"SubscriptionStore drops a lower id delivered after a higher id (witness)"`.
- `"ExecutorListener drops a lower executor.* id delivered after a higher id (witness)"`.
- `"ExecutorListener wake path delivers both ids regardless of order (witness)"`.

```bash
env -C <worktree>/src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= \
  mise exec -- mix test test/aiur/events/out_of_order_id_witness_test.exs
```

Mutation check: change `subscription_store.ex:398` from `event_id <= cursor` to
`event_id == cursor` in a worktree; the first test must fail (low is now
enqueued). Change `executor_listener.ex:173` to drop the watermark clause; the
second must fail. Record the commands and `git status --porcelain` output.

## Completion and handoff

- [ ] Three witness tests green on main; both mutations fail them.
- [ ] Finding paragraph in the PR body, linked from contract §5 item 3 (by C4-T05).
- [ ] If the drop is confirmed: notify the U3 event-delivery owner with the test
      name; do not change production code here.
- Docs: none.
- Dependents: U3 event-delivery ticket (input), C2-T01 (must keep the test green or
  update it with U3's reviewed fix).

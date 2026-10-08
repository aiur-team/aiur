---
ticket_id: MP-E7-C3-T01
feature_id: MP-E7
chunk_id: MP-E7-C3
bucket: 2-platform
title: "Queue items for listener sends: listener_mode_at_claim stamp, async hold that no claim path takes, pending re-stamp"
status: blocked
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, MP-R7-C1-T02]
prior_units: [U3, U4]
prior_boundaries: [MSG (16), RUN (18)]
prior_features: [integrations-43, subsystems-14]
prior_findings: [agent-runtime-01]
size_owner: AGENT_TURN (agent_queue_store.ex, 597 lines: ≤ 25 added lines, no new responsibilities; agent_queue.ex 54 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C3-T01 — Queue item support for listener sends

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C3 (route every send
  through the mode).
- **User value:** the queue can hold a message in each mode's shape — sync
  (turn boundary), emulated steer (interrupt), async (persisted, never
  delivered by aiur) — and the mode a message was delivered under is recorded.
- **Deliverable:**
  1. `Aiur.AgentQueue.operator_message/3` (`agent_queue.ex:6-32`) accepts
     `listener_mode: :steer | :sync | :async` and `steer_carrier:` in opts.
     For `:async` it builds `consume_at: :pull`, `priority: :later`,
     `interrupt_requested: false`, `immediate: false`. It always writes
     `delivery.listener_mode_at_claim` (the mode the flags were derived from).
     Without `listener_mode` the map is byte-identical to today.
  2. `Aiur.AgentQueueStore`: `next_pending_item/2` and
     `next_pending_item_matching/3` (`agent_queue_store.ex:395-410`) skip items
     with `delivery.consume_at == :pull`, so **no** claim path (resume,
     checkpoint, blocker digest, operator, response; `operator_messages.ex:369-440`)
     can take an async-held item.
  3. `AgentQueueStore.update_pending_delivery(store, target, fun)` (PROPOSED):
     applies `fun.(delivery)` to each `:pending` item of `category:
     :operator_message` whose delivery has `listener_mode_at_claim`; claimed
     (`:delivered`) and terminal items are never touched (contract §3 rule 6:
     "a message already claimed keeps the mode it was claimed under").
- **Non-goals:** no policy decision (C3-T02); no entry-point change (C3-T03);
  no pull tool (`aiur_read_messages`, MP-E7-C5).

## Dependencies and blockers

- DESIGN-E7; **MP-R7-C1-T02** (delivery-matrix characterization must exist
  first so this ticket proves "no listener_mode ⇒ unchanged").
- Concurrent with MP-E7-C2-*, MP-E7-C1-*.
- Successors: MP-E7-C3-T02, MP-E7-C5-T01.

## Verified starting point (aiur `45a290e3`)

- Queue item builder: `AgentQueue.operator_message/3` derives
  `priority`, `consume_at`, `interrupt_requested`, `immediate` from
  `delivery_policy` (`agent_queue.ex:9-26`).
- Item statuses `:pending | :delivered | :consumed | :failed | :superseded`
  (`agent_queue_item.ex:6`). No "held" status; adding one would touch every
  status consumer, so the hold is expressed in `delivery.consume_at` instead.
- Claims all funnel through two private selectors filtering `status ==
  :pending` (`agent_queue_store.ex:395-410`), called by
  `claim_next_deliverable/2` (:140-163) and `claim_next_deliverable_matching/3`
  (:166-191); every Orchestrator claim uses one of them
  (`operator_messages.ex:374,381,396,412,426`; `digest_coalescer.ex:25`).
- `list_pending/2` (:314-321) feeds `queue_depth`
  (`capabilities.ex:9-13`); held async items will count there (they are
  pending), which is correct until MP-E7-C5 adds the unread count.
- The store is in memory only (`agent_queue_store.ex:2-3`; `state.ex:234`):
  pending messages, held or not, do not survive a daemon restart today. This
  ticket does not change that (contract correction reported to the parent).
- Related tests: `src/test/aiur/agent_queue_test.exs` (538 lines; flags at :93-127); store behaviour is
  covered there and in `orchestrator/operator_messages/*_test.exs`.

## Chosen design

| `listener_mode` | priority | consume_at | interrupt_requested | immediate |
| --- | --- | --- | --- | --- |
| absent (today) | per `delivery_policy` (unchanged) | per policy | per policy | per policy |
| `:sync` | `:next` | `:safe_checkpoint` | false | false |
| `:steer` + `steer_carrier: :emulated_interrupt` | `:now` | `:safe_checkpoint` | true | false |
| `:steer` + `:native` | reserved for MP-E7-C4-T02, which adds a `steer_requested: true` item flag and a `:steer` wake value; until then this row raises `ArgumentError` | | | |
| `:async` | `:later` | `:pull` | false | false |

The delivery map is open (plain map, `agent_queue_item.ex:18`), so the C4
flag is additive; C3-T01 must not pattern-match the map exhaustively.

Rationale: sync and emulated-steer rows are exactly today's `:checkpoint` and
`:interrupt` rows, so every existing claim, wake and interrupt path handles
them unchanged; only `:pull` is new.

Re-stamp (`update_pending_delivery/3`) replaces the whole delivery map with
the row for the new mode, so pending messages follow a mode change
(contract §6 `steer ↔ sync` and `any → async`). `async → sync/steer` for
items already held is **not** decided here (E7-D4; MP-E7-C5-T03).

## Implementation steps

1. `agent_queue.ex`: add the `listener_mode` branch (~20 lines).
2. `agent_queue_store.ex`: add `pull_held?/1` predicate to the two selectors (+4 lines) and `update_pending_delivery/3` (~18 lines).
3. Tests in a new `src/test/aiur/agent_queue_listener_test.exs` (the existing `agent_queue_test.exs` is 538 lines, already over the 500 gate).

## Non-happy paths

- An item enqueued with `consume_at: :pull` before a restart is lost with the
  rest of the in-memory queue (same as today's pending items).
- `update_pending_delivery/3` must not touch Command answers or digests
  (`category: :coordination_event` and correlated items carry no
  `listener_mode_at_claim`).

## Compatibility and rollout

- Callers that pass no `listener_mode` see no change; nothing passes it until
  MP-E7-C3-T02/T03 with routing `:listener`. Rollback: revert.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/agent_queue_test.exs test/aiur/agent_queue_listener_test.exs test/aiur/orchestrator/operator_messages
env -C src mise exec -- mix test test/aiur/delivery_entry_points_test.exs test/aiur/orchestrator/operator_messages/delivery_matrix_test.exs   # MP-R7-C1-T02 suite, must be unchanged
```

Tests:

- "operator_message without listener_mode is byte-identical to the checkpoint and interrupt rows" (guard for compatibility; already passes; named as such).
- "sync listener item has checkpoint flags and listener_mode_at_claim sync".
- "async listener item is never returned by claim_next_deliverable or claim_next_deliverable_matching".
- "async item still counts in list_pending".
- "update_pending_delivery re-stamps pending sync items to emulated steer and leaves delivered items untouched".
- "update_pending_delivery leaves coordination events and correlated items untouched".

Mutation checks: remove the `:pull` skip from `next_pending_item/2` → the
"never returned" test fails (it calls both claim functions); let the re-stamp
touch `:delivered` items → the "leaves delivered untouched" test fails.

## Completion and handoff

- [ ] Builder and store changes merged; R7-C1-T02 matrix unchanged.
- [ ] `agent_queue_store.ex` growth ≤ 25 lines (AGENT_TURN owner notified in the PR).
- Dependents: MP-E7-C3-T02, MP-E7-C5-T01 (pull tool claims `:pull` items explicitly).
- Docs: none.

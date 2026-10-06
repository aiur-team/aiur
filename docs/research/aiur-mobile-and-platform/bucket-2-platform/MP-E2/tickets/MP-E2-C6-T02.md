---
ticket_id: MP-E2-C6-T02
feature_id: MP-E2
chunk_id: MP-E2-C6
bucket: 2-platform
title: Deliver answers to the Executor through its journal and wake inbox
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C6-T01, MP-E2-C2-T02]
prior_units: [U6, U3]
prior_boundaries: [DEC #27, EXE #26]
prior_features: [MP-E3 (optional session injection), MP-R1 migration S4 (Executor attention binding = U3 + MP-E2)]
prior_findings: [D12, contract §7.2; executor_listener.ex:183-193 and executor_wake_projection.ex:12 ignore executor.* today]
size_owner: "U3 owner for executor_listener.ex / executor_wake_projection.ex (narrow allowlist only); DECISIONS (one dispatchability guard; decision.ex delivered?/1)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C6-T02 — Deliver answers to the Executor through its journal and wake inbox

## Identity and outcome

- Bucket 2, MP-E2, chunk C6.
- **User value:** when you answer the Executor's question, the Executor gets it on its
  next `aiur executor-wait` — even if it restarted — and the answer is never sent to a
  worker by mistake.
- **Deliverable:**
  1. Worker dispatch is skipped for Executor-requester Commands.
  2. `executor.decision.answered` (C1-T03 topic) reaches the wake inbox:
     `ExecutorListener.deliver/2` and `ExecutorWakeProjection.project/1` allowlist that one
     topic and include `decision_id` in the wake record.
  3. PROPOSED `Aiur.Commands.ExecutorDelivery` records `requester_notified` once the wake
     record is enqueued; `Decision.delivered?/1` treats it as delivered (so D11 supersede
     is refused afterwards).
- **Non-goals:** injecting into the Executor's chat session (MP-E3; add later behind the
  same module); UI.

## Dependencies and blockers

- **DESIGN-E2**; C6-T01; C2-T02 (`record_command_fact/4`, add `requester_notified`).
- **U3 coordination:** U3 owns ordering/claims in the wake inbox
  (`executor_wake_inbox.ex`) and its listener. This ticket uses only the public
  `ExecutorWakeInbox.enqueue/2` result and changes the projection allowlist; announce the
  edit to the U3 owner (prior plan U3 MP cross-references: "MP-E2-C6 uses only the wake
  inbox's public API").

## Verified starting point (`45a290e3`)

- `src/lib/aiur/executor_listener.ex:183-193` `deliver/2`: `executor_topic?` events only
  emit a command alert; non-executor events → `ExecutorWakeProjection.project/1` →
  `ExecutorWakeInbox.enqueue/2` (`:187`). `@command_topics` `:19`.
- `src/lib/aiur/executor_wake_projection.ex:9-42`: `project/1` returns `:ignore` for any
  `executor.` topic (`:12`); record keys `wake_id`, `topic`, `ticket`, … (no
  `decision_id`).
- `src/lib/aiur/executor_wake_inbox.ex:24` `enqueue/2 :: :ok`.
- `src/lib/aiur/executor_events.ex:200-216` scrubbed command topics.
- Dispatch scheduling after an answer: `maybe_schedule_after_answer/3`
  `decision_store.ex:3735`; `dispatchable?/2` clauses `:4513-4518`; redelivery
  `:4562-4601`.
- `src/lib/aiur/decision.ex:234-240` `delivered?/1`.
- `aiur executor-wait` reads `ExecutorWakeInbox.wait/2` (`agent_control_cli.ex:444-520`).

## Chosen design

- **Skip dispatch:** `dispatchable?/2` (store) returns false when
  `Requester.executor?(decision)` — via `Aiur.Commands.Requester`, one clause.
- **Projection allowlist:** in `ExecutorWakeProjection.project/1`, before the
  `executor.` exclusion: topic `"executor.decision.answered"` → record with
  `"topic"`, `"topic_class" => "executor.decision"`, `"decision_id"`, `"action" =>
  "answered"`, `"event_id"/"wake_id"` from the event id, `"ticket" => nil`.
  `ExecutorListener.deliver/2`: for that topic, call the projection + enqueue (in addition
  to the existing command alert path, which stays unchanged for requested/deferred).
- **Payload privacy:** the wake record carries ids only; the Executor reads the answer with
  `aiur commands <id> --json` (the answer is human-authored text; it is scrubbed like other
  command fields if C1-T03 put it in the journal payload — add the topic to
  `@command_topics` in `executor_events.ex:200`).
- **Evidence:** `ExecutorDelivery.on_enqueued(decision_id, action_id)` →
  `record_command_fact(id, :requester_notified, %{action_id, at, channel: :wake_inbox})`.
  Projection sets `requester_notified_at`; `Decision.delivered?/1` gains
  `or not is_nil(decision.requester_notified_at)`.
- **Restart:** the journal is durable; `ExecutorListener` replays executor journal events
  above its watermark on boot (existing behaviour, `executor_listener.ex:133-166`), so an
  answer published while the listener was down is enqueued after restart; the fact write
  is idempotent (first only).

## Implementation steps

1. `commands/requester.ex`: `dispatch_target/1` (`:worker | :executor`).
2. `decision_store.ex`: one clause in `dispatchable?/2` (`:4513-4518`).
3. `executor_wake_projection.ex`: allowlist clause (≈20 lines).
4. `executor_listener.ex`: enqueue for the allowlisted topic; call `ExecutorDelivery`.
5. PROPOSED `src/lib/aiur/commands/executor_delivery.ex` (≈60 lines).
6. `requester_notified` in `EventData`/`Projection`; `decision.ex` `delivered?/1` clause.
7. `executor_events.ex:200`: add the topic to scrubbed command topics.

## Non-happy paths

- Enqueue fails (inbox down): `:ok = deliver(…)` raises, the rescue logs, and the
  watermark is **not** advanced (`executor_listener.ex:144-166`), so the next replay
  (`replay_and_deliver/2` `:133-142`) retries; no fact is recorded until it succeeds.
- Two Executors: the shared inbox delivers once to the lease owner (U3 semantics).
- Human supersedes before the Executor read it: allowed until `requester_notified`; after
  it, refused as delivered (D11 "until delivered").
- Answer to an Executor Command with `--ticket` context: still Executor delivery only.

## Compatibility and rollout

- Additive topic in the wake inbox; Executors that do not know it see an extra record type
  (`topic_class` new) — the aiur-run skill (C8-T02) documents it.
- Rollback: older binaries ignore the topic and the fact.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/commands/executor_delivery_test.exs test/aiur/executor_listener_test.exs \
  test/aiur/executor_wake_projection_test.exs test/aiur/decision_store_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "answering an executor-originated Command dispatches nothing to a worker" | no `send_correlated_operator_message` call | step 2 |
| "executor.decision.answered projects to a wake record with decision_id" | record fields as specified | step 3 |
| "listener enqueues the answered record and records requester_notified" | inbox has the record; fact recorded once | steps 4–5 |
| "supersede after requester_notified is refused as delivered" | `{:conflict, :answer_delivered}` | step 6 |
| "listener restart replays an answer published while down" | record enqueued after restart, one fact | watermark replay |
| "executor-wait returns the answered record" (integration via `ExecutorWakeInbox.wait/2`) | one record with the decision id | end to end |

Mutation check per row. Manual: `aiurdev --test`; `scripts/aiurdev command request …`;
answer in `/commands`; `scripts/aiurdev executor-wait --json` prints the answered record.

## Completion and handoff

- [ ] Dispatch skipped; wake delivery; delivered evidence; scrubbed payload.
- Docs: `concepts/executor.md` (Executor asks the human; answers arrive on
  `executor-wait`), `reference/cli.md` (`executor-wait` record type).
- Dependents: C6-T03, C8-T02, MP-E3 (session injection hook).

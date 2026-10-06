---
ticket_id: MP-E2-C4-T03
feature_id: MP-E2
chunk_id: MP-E2-C4
bucket: 2-platform
title: In-band delivery — answer a held native question through the operator queue
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C4-T02, MP-E2-C3-T02]
prior_units: [U4, U6]
prior_boundaries: [RUN #18, DEC #27, CDX #21]
prior_features: [MP-R7 (reply_native_question/3), MP-E7 (send routing; must not double-deliver)]
prior_findings: [contract §7.1, harness-adapter §6 item 4 (answers to the asking session)]
size_owner: "DECISIONS (decision_dispatch.ex 108); AGENT_CORE (checkpoint_delivery.ex 235, turn_callbacks.ex, app_server/interrupts.ex 76)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C4-T03 — In-band delivery through the operator queue

## Identity and outcome

- Bucket 2, MP-E2, chunk C4.
- **User value:** when you answer a held native question, the agent receives it as the
  real tool result (structured, every question answered) and carries on in the same turn.
- **Deliverable:**
  1. `DecisionDispatch` marks the correlated operator message with `native_ref` and
     `question_answers` when `native.hold == :in_band`.
  2. The runner holding that `native_ref` claims that item, replies to the JSON-RPC
     request, emits `:native_question_resolved`, and acknowledges the item through the
     existing provider-delivery path, so `delivered` evidence and #2713 redelivery work
     unchanged.
  3. If no runner holds the ref, the item is an ordinary message (today's path).
- **Design choice (TKD-13):** the store's dispatcher contract (`settle_dispatch` expects a
  queue item, `decision_store.ex:4001-4020`) stays unchanged; in-band is chosen by the
  process that holds the request — the only process that can know it is still pending.

## Dependencies and blockers

- **DESIGN-E2**; C4-T02 (hold); C3-T02 (`question_answers` encoding and
  `render_question_answers/2`).
- MP-R7: after R7, the runner calls the adapter's `reply_native_question/3`; before R7,
  `Aiur.Commands.NativeCapture.Codex.reply/3` writes the frame.
- MP-E7-C3 (send routing through listener mode): its router must pass
  `native_ref`-correlated items through untouched (note for E7; no change here).

## Verified starting point (`45a290e3`)

- `src/lib/aiur/decision_dispatch.ex:36-66` builds `correlation` and `payload`
  (`delivery_policy: :interrupt`, `fallback: :queue_next`) and calls
  `OperatorMessages.send_correlated_operator_message/3` with the ticket; `:93-107`
  `response_text/2`.
- Runner callbacks: `agent_runner/turn_callbacks.ex:15-61` builds `on_safe_checkpoint`
  from `CheckpointDelivery.safe_checkpoint_handler/5` (`checkpoint_delivery.ex:68-114`,
  claims via `Aiur.Orchestrator.claim_next_checkpoint_queue_item/2` `:124-130`).
- Delivery evidence: `agent_runner/queue_drain.ex:300-320`
  `acknowledge_provider_delivery/3` → `Aiur.Orchestrator.acknowledge_queue_item_delivery/3`
  (`orchestrator.ex:629-632`); `record_provider_delivery/3` (`queue_drain.ex:~270-297`).
- Queue update trigger: `app_server/turn_loop.ex:31-33` → `Interrupts.handle_operator_queue_update/2`
  (`app_server/interrupts.ex:35-54`).
- Store gate before send: `DecisionStore.validate_delivery/2` (`decision_store.ex:349-355`).

## Chosen design

1. **Mark.** In `DecisionDispatch.dispatch/2`, when `decision.native` has
   `hold: :in_band` (from C1-T01 attributes): add `native_ref` and
   `question_answers` (decoded via `Answering.decode_question_answers/2`; a v1 single
   answer maps to `%{first_question_id => [label | custom]}`) to `correlation`.
   `render/1` uses `render_question_answers/2` for the text body, so the message fallback
   is readable.
2. **Claim.** PROPOSED `CheckpointDelivery.native_reply_handler/3` (callback
   `on_native_reply` in `TurnCallbacks`): given the set of held refs, claim the first
   queued item whose `correlation.native_ref` is in the set (new orchestrator call
   PROPOSED `claim_native_reply_item(server, identifier, refs)` in `OperatorMessages`,
   matching on correlation only), run `DecisionStore.validate_delivery/2`, return
   `{:reply, ref, answers, on_success, on_failure}` or `:none`.
3. **Reply.** `Interrupts.handle_operator_queue_update/2` with held questions calls
   `on_native_reply`; on `{:reply, …}` it writes
   `{"id": request_id, "result": {"answers": %{qid => %{"answers" => list}}}}` (Codex shape
   from C4-T00), removes the ref from `held_native_questions`, emits
   `:native_question_resolved` (`reason: :answered`), and calls `on_success` with provider
   metadata `%{provider: :native_reply, native_ref: ref}` (→ `acknowledge_provider_delivery/3`
   and `record_provider_delivery/3`). Port write failure → `on_failure` (item restored;
   later message delivery).
4. Same check runs once right after a hold starts (an answer may already be queued, e.g.
   the Executor answered within milliseconds).

## Implementation steps

1. `decision_dispatch.ex`: correlation keys + render (≈15 lines).
2. `orchestrator/operator_messages.ex`: `claim_native_reply_item/3` (PROPOSED; ≈30
   lines; this file is 1,167 lines — put the matcher in a new
   `orchestrator/operator_messages/native_reply.ex` and add one delegating clause).
3. `agent_runner/checkpoint_delivery.ex` + `turn_callbacks.ex`: `on_native_reply`.
4. `app_server/interrupts.ex`: held branch.
5. `commands/native_capture/codex.ex`: `reply/3` frame writer.

## Non-happy paths

- Answer for a ref no longer held (turn ended, released): no runner claims it ⇒ normal
  message delivery (the agent was told by the release text to expect a message).
- Two answers (supersede before delivery): the store refuses the replaced copy at
  `validate_delivery/2`; only the active action is replied.
- Multi-select / Other: list of labels or custom strings, as recorded.
- Partial answers: impossible — C3-T02 rejects incomplete multi-question answers.
- Ordering with other operator items: a native reply jumps ahead of unrelated items
  (they cannot be delivered while the tool is held anyway).

## Compatibility and rollout

- Only active when C4-T02's gate is on. Message delivery unchanged otherwise.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/decision_dispatch_test.exs test/aiur/agent_runner/checkpoint_delivery_test.exs \
  test/aiur/app_server/interrupts_test.exs test/aiur/decision_delivery_integration_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| `decision_dispatch_test` "in-band Command adds native_ref and question_answers to correlation" | keys present; v1 Command unchanged | step 1 |
| `interrupts_test` "held ref + matching queue item writes the exact answers frame" | frame equals C4-T00 `after_reply` request shape with label "red" | step 4 |
| "non-matching item while held does not interrupt" | no frame, `{:continue, _}` | held guard |
| `decision_delivery_integration_test` "in-band reply records delivered" | Decision `delivered?/1` true, `delivery_status: :delivered` | step 3 on_success wiring |
| "answer after release goes as a message" | operator message text contains rendered answers | no-claim fallback |
| "superseded answer is not replied in-band" | only the active action's frame is written | `validate_delivery/2` call |

Mutation check per row. Manual: AGENTS.md wrapper-tmux `aiurdev --test` with the C4-T02
scratch config; answer the Command in `/commands`; in pane `0.1` the agent continues the
same turn using the answer (look for the tool result line, not a new user message).

## Completion and handoff

- [ ] In-band path + fallback; delivered evidence identical to message delivery.
- Docs: `concepts/commands.md` delivery paragraph (C8-T01).
- Dependents: C4-T04, C5-T02, MP-E4 (anchor on `native_question_resolved`).

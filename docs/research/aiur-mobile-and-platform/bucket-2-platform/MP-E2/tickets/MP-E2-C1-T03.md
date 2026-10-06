---
ticket_id: MP-E2-C1-T03
feature_id: MP-E2
chunk_id: MP-E2-C1
bucket: 2-platform
title: Route Command lifecycle topics by requester and prove rollback safety
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C1-T01]
prior_units: [U6, U3]
prior_boundaries: [DEC #27, EXE #26]
prior_features: [MP-R2 (topic grammar frozen, events-and-replay §9)]
prior_findings: [R-Q4, RC-08, contract §8, §11]
size_owner: "DECISIONS (decision_store.ex — two call sites replaced, no growth)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C1-T03 — Route Command lifecycle topics by requester and prove rollback safety

## Identity and outcome

- Bucket 2, MP-E2, chunk C1.
- **User value:** an Executor-originated Command never produces a fake
  `ticket.executor.*` topic; its lifecycle reaches the Executor journal. Rollback to an
  older release is proven not to wedge the Command store.
- **Deliverable:** PROPOSED `Aiur.Commands.Topics` with `lifecycle/2` and `publish/3`;
  the two literal topic builders in `decision_store.ex` call it; a rollback-safety test
  suite.
- **Non-goals:** new slugs other than `request-attributed` (each later ticket adds its
  own); wake-inbox projection of `executor.decision.answered` (C6-T02); MP-R2 catalog
  entries (MP-R2-C5-T01, RC-08).

## Dependencies and blockers

- Blocked by **DESIGN-E2**; predecessor C1-T01 (requester helpers).
- Cross-feature: MP-R2 freezes the grammar (`events-and-replay.md` §9) — this ticket adds
  no new prefix, only uses `executor.decision.*` which `ExecutorEvents` already owns.
  If MP-R2-C5-T01 has landed, confirm its catalog lists `executor.decision.*` as
  journaled; otherwise nothing to register.
- May run concurrently with C1-T02, C1-T04.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/decision_store.ex:2554-2561` `notify_lifecycle/3` builds
  `"ticket.#{decision.ticket.identifier}.agent.decision.#{lifecycle_slug(event.type)}"`
  and calls `Publisher.publish_persisted/3`.
- `:4603-4621` `notify/3` builds `"ticket.#{decision.ticket.identifier}.agent.decision.requested"`,
  then `notify_requested_executor/4` (`executor.decision.requested`), then
  `DecisionPubSub.broadcast_changed/2`.
- `src/lib/aiur/executor_events.ex:64` `publish/3`; `:266-270` `validate_publish_topic/1`
  (`executor.` prefix); `:200` `@command_topics` (requested, deferred) whose payload fields
  are scrubbed; `:59-60` `publish_requested/1`.
- Rollback mechanics: `decision_event.ex:167-193`, `decision_event/unrecognized.ex`,
  `decision_projection.ex:158`; existing tests `decision_projection_test.exs:937-967`,
  `decision_store_test.exs:4440-4474`.

## Chosen design

```elixir
# PROPOSED src/lib/aiur/commands/topics.ex
@spec lifecycle(Decision.t(), String.t()) :: String.t()
def lifecycle(decision, slug) do
  case Requester.kind(decision) do
    :executor -> "executor.decision." <> slug
    :worker -> "ticket.#{decision.ticket.identifier}.agent.decision." <> slug
  end
end

@spec publish(Decision.t(), String.t(), map(), pos_integer() | String.t()) :: :ok
# worker  -> Publisher.publish_persisted(topic, payload, cursor_event_id, digest_source: :orchestrator)
# executor-> ExecutorEvents.publish(topic, scrubbed_payload, source: :internal)
```

- Executor-requester payloads go through `ExecutorEvents.scrub_untrusted_output/1`
  (add `executor.decision.requested`-like scrubbing by extending `@command_topics` with
  `executor.decision.answered` only when C6-T02 lands — not here).
- For an Executor requester, `notify/3` must **not** also call
  `notify_requested_executor/4` (the requested event already went to the Executor journal
  by `publish/4`); one guard.
- Invariant: every topic produced matches the frozen grammar; no `ticket.executor.` topic
  is ever published by a new binary.

## Implementation steps

1. PROPOSED `src/lib/aiur/commands/topics.ex` (≈70 lines).
2. `decision_store.ex:2554-2561`: replace the topic literal + publish with
   `Topics.publish(decision, lifecycle_slug(event.type), DecisionEvent.to_json_safe(event), cursor_event_id)`.
3. `decision_store.ex:4603-4621`: same for `requested`; skip `notify_requested_executor/4`
   when `Requester.executor?(decision)`.
4. Tests below, including the rollback suite.

## Non-happy paths

- `ExecutorEvents.publish/3` error for an Executor requester: same handling as today's
  lifecycle publish (log warning, no crash; `decision_store.ex:2556-2561` rescue). State is
  still replayable from the store (contract §8).
- A worker Command whose requester event is missing (C1-T01 failure branch) → worker
  topic, i.e. today's behaviour.

## Compatibility and rollout

- Worker topics byte-identical to today (test). Executor topics are new and only appear
  once C6-T01 creates Executor Commands.
- Rollback: proven by the suite below; release note from contract §11.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/commands/topics_test.exs test/aiur/decision_store_test.exs test/aiur/decision_projection_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| `topics_test` "worker topic unchanged" | `ticket.123.agent.decision.answered` for slug `answered` | `lifecycle/2` worker clause |
| `topics_test` "executor requester topic" | `executor.decision.answered` | executor clause |
| `decision_store_test` "executor-originated request publishes executor.decision.requested once and no ticket topic" | capture publisher: exactly one `executor.decision.requested`, zero `ticket.executor.*` | steps 2–3 |
| `decision_store_test` "worker request still publishes ticket topic and executor event" | both published, as today | step 3 guard |
| `decision_projection_test` "every MP-E2 fact type round-trips through Unrecognized decode" | for each of `EventData.fact_types()`, `Unrecognized.decode(to_json_safe(event), type_string)` → `{:ok, _}` and `DecisionProjection.reduce/1` with that record wrapped as Unrecognized leaves the Decision unchanged | encoding in C1-T01 (guard against a future fact type with a malformed envelope) |

The whole-store "older binary keeps writing" behaviour is already covered at base by
`decision_store_test.exs:4440-4474` (a `some_future_event` line keeps the store writable
and retained on disk). Row 5 proves each new type takes that path; no new store-level
simulation is added (there is no injectable decoder to stub, and none is introduced).

Mutation check: rows 1–4 per AGENTS.md. Row 5 must fail if a fact type's JSON drops
`run_id` or `content_hash` (revert the encoding helper in `Aiur.Commands.EventData`).

## Completion and handoff

- [ ] Two call sites use `Topics`; no `ticket.executor.` topic possible.
- [ ] Rollback suite present.
- Docs: none user-facing here; C8-T01 documents topics in `concepts/commands.md`.
- Dependents: C2-T02 (human-needed topic), C6-T02 (answered topic), MP-N4/N5.

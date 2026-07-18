# OCC-3 answer and delivery contract

**Status:** Implemented in #981

**Foundation:** [`03-occ-1-decision-contract.md`](./03-occ-1-decision-contract.md)

This is the application-service and agent-handoff contract for OCC-4, OCC-7,
and OCC-8. OCC-3 accepts an immutable answer, persists it before dispatch,
delivers it through the legacy `operator-message` queue owned by
`Aiur.Orchestrator.OperatorMessages`, and correlates every transport and agent
lifecycle fact back to that answer.

## Public service boundary

`Aiur.DecisionStore` remains the only writer and the service downstream callers
must use. UI and API callers must not publish lifecycle topics or call
`OperatorMessages` directly.

### Submit an answer

```elixir
Aiur.DecisionStore.answer(
  decision_id,
  %{
    "idempotency_key" => "browser-submit-token",
    "expected_version" => 3,
    "option_id" => "approve",
    "rationale" => "Checks are green"
  },
  actor: %{kind: :operator, id: operator_id}
)
```

The payload requires:

- a caller-stable `idempotency_key`;
- the exact `expected_version` rendered to the caller;
- exactly one of `option_id` or `custom_response`;
- optional bounded `rationale`.

The actor comes from trusted runtime context; an actor in the payload is
ignored. The store derives `action_id` from the Decision and idempotency key, so
retries of one submission retain an identity without colliding with another
Decision.

Success returns:

```elixir
{:ok, %{
  status: :accepted | :duplicate,
  decision: decision,
  action: answer,
  dispatch_status: :dispatch_pending | delivery_status
}}
```

An exact replay is `:duplicate` and appends or enqueues nothing. Reusing the
same action with different content is an idempotency conflict. A different
action after another answer won is an already-decided conflict. An answer to an
older request is `{:conflict, {:stale_version, submitted, current}}` and mutates
nothing. Callers should re-read `DecisionStore.get/1` after any conflict.

### Retry a failed delivery

```elixir
Aiur.DecisionStore.retry_dispatch(decision_id, action_id)
```

This accepts the current failed action or an action whose background lifecycle
append exhausted its bounded retries. Orchestrator availability failures
receive bounded automatic retries; a missing target agent waits for this
deliberate retry. A retry creates a new attempt, restores the same failed queue
item, or reconciles its current snapshot without creating another logical
action.

### Read models

- `get/1` and `list/0` return current projections.
- `history/1` returns request versions, for OCC request/revision presentation.
- `audit_history/1` returns the complete ordered request, answer, transport, and
  agent lifecycle history.

Clients must re-read on mount/reconnect. PubSub and Exchange are invalidation
signals, not state.

## Persist-before-dispatch invariant

Answer acceptance follows this order:

1. validate version, answer, actor, and idempotency;
2. append and fsync `answer_recorded`;
3. atomically replace `decisions.json`;
4. publish the persisted answer event and Decision PubSub invalidation;
5. asynchronously dispatch through
   `Aiur.Orchestrator.OperatorMessages.send_correlated_operator_message/3`.

Failure before step 3 dispatches nothing. A crash after step 3 is recovered by
the outbox reconciliation pass. Queue acceptance is separately appended as
`dispatch_queued`; canonical audit bytes, rather than an in-memory task, decide
what happens after restart.

## Two independent state axes

Decision meaning and transport evidence intentionally do not collapse into one
status:

| Axis | Values | Meaning |
|---|---|---|
| `decision_status` | `open`, `decided`, `acknowledged`, `resolved` | Semantic lifecycle of the requested choice. |
| `delivery_status` | `not_dispatched`, `pending`, `queued`, `delivered`, `consumed`, `failed` | Best durable evidence about answer transport. |

`consumed` means the queue item retired after an agent turn; it does **not**
mean the agent acknowledged or completed the action. Acknowledgement and
resolution only advance through explicit trusted agent events. A transport
failure can coexist with a decided or acknowledged Decision.

Each dispatch attempt records `action_id`, durable `attempt_id`, queue-local
`queue_item_id`, run ID, timestamps, and a bounded failure class. Queue item IDs
are local to an Orchestrator lifetime and may repeat after restart; the attempt
ID is the durable discriminator.

## Durable event meanings

`decisions.ndjson` is append-only. New records use the hashed
`Aiur.DecisionEvent` envelope:

| Event | Durable meaning |
|---|---|
| `requested` | Accepted request version. |
| `answer_recorded` | Immutable Executor/supervisor answer accepted. |
| `dispatch_queued` | One correlated queue attempt exists. |
| `delivered` | The store synchronously recorded backend handoff before answer text was exposed to the agent. |
| `restored` | A failed or delivered queue item became pending again. |
| `consumed` | The queue item retired after its turn. No semantic acknowledgement is implied. |
| `failed` | Dispatch or transport failed with a bounded reason class. |
| `acknowledged` | The trusted target agent explicitly observed the action. |
| `resolved` | That agent explicitly reported the correlated work complete. |

Every event contains the Decision ID, the request version addressed by the
answer, a reserved event ID, run ID, canonical occurrence time, and a content
hash. Replay validates both hashes and legal transitions. Interior corruption
leaves validated-prefix reads available but makes all mutation and dispatch
read-only until repaired.

## Queue and restart correlation

`DecisionDispatch` renders a bounded Executor message containing the question,
selected/custom answer, rationale, trusted actor, Decision ID, addressed
version, immutable action ID, replay warning, and exact acknowledgement and
resolution instructions.

The queue item carries:

```elixir
%{
  action_id: action_id,
  correlation: %{
    decision_id: decision_id,
    decision_version: answered_version,
    action_id: action_id,
    attempt_id: attempt_id,
    actor: actor,
    answer_content_hash: answer_content_hash
  }
}
```

`AgentQueueStore` indexes that action for the queue lifetime. An exact send
replay returns the existing item in any state and does not notify the worker;
changed content conflicts. A failed-item retry restores that item once.

Restart behavior is explicit:

- A persisted answer with no queue attempt is dispatched on Store startup.
- If the Store restarts but the Orchestrator survives, reconciliation finds the
  existing action, adopts its current queue snapshot, and does not wake the
  agent twice.
- If both restart and the old in-memory queue is gone, a still-queued,
  unacknowledged action gets a new attempt under the same action ID. Reuse of a
  queue-local numeric ID is safe.
- Delivered, consumed, acknowledged, and resolved actions are not blindly
  duplicated on reconnect.
- A queue snapshot already marked delivered, consumed, or failed fills in any
  missing durable transport edges when reconciliation completes.

The backend-handoff edge has two synchronous boundaries. Before exposing
correlated answer text, `QueueDrain`/`CheckpointDelivery` must receive
`{:ok, ...}` from the non-mutating `DecisionStore.validate_delivery/2` check.
Only the provider's subsequent receipt callback may persist
`DecisionStore.record_delivery/2`. If provider receipt beats asynchronous
dispatch settlement, that callback adopts the missing queued edge before
recording delivery instead of bouncing the item. Other correlation failures
withhold the text and restore the item for at most three claims; exhaustion
marks the item failed and opens one stable attention. A later explicit action
retry resets that claim budget. Restore/consume/fail updates from one queue
mutation are batched into one Store message and one projection rewrite; the
successful agent turn is not retroactively converted into a failure.

## Explicit agent acknowledgement

Only exact `decision.acknowledged` and `decision.resolved` tool events route to
`DecisionStore.agent_lifecycle/4`. Their payload is:

```json
{
  "decision_id": "dec_...",
  "action_id": "act_...",
  "expected_version": 3,
  "detail": "optional bounded detail"
}
```

The tool boundary injects the trusted ticket, stable target-agent actor, backend
identity, session, and invocation. Payload-supplied actor or ticket identity
cannot advance state. The ticket, action, and answered request version must all
match; acknowledgement requires durable delivery, and resolution requires
acknowledgement. Exact replay across a reconnect is a duplicate, while changed
detail or correlation conflicts.

Generic `decision.<slug>` coordination events remain supported, but direct
publication of the reserved `requested`, `acknowledged`, and `resolved`
families is rejected so callers cannot bypass persistence.

## Failure projection

A durable failed attempt emits one stable Executor attention:

```text
ticket.<ticket>.agent.attention.decision-delivery-<action-slug>
```

Store restart reprojects unresolved failures. `AlertFeed` collapses repeated
open records for that ticket/slug. Queue acceptance/restoration/delivery or an
explicit acknowledgement emits the matching `.resolved` record, removing it
from the active attention view while preserving append-only history.

Only bounded reason classes are persisted; arbitrary exception terms and
credentials are not copied into Decision audit data.

## Intentionally deferred

- OCC-4 owns the inbox/detail LiveView and answer form.
- OCC-7 owns the public machine-readable Decision API and supervising-agent
  policy.
- OCC-8 extends this exact action/outbox contract through
  [`05-occ-8-decision-revision-contract.md`](./05-occ-8-decision-revision-contract.md).
  The original OCC-3 answer remains immutable; `DecisionStore.revise/5`
  appends a new active action and reuses correlated queue attempts rather than
  replacing the answer or introducing another dispatcher.
- OCC-2 owns adaptation of legacy attention/block/pause signals into Decisions.
- OCC-5/6/9 own fleet presentation, history UX, and metrics derived from this
  audit stream.

Those consumers extend this service and projection; they must not introduce a
second Decision writer, queue path, or lifecycle inference.

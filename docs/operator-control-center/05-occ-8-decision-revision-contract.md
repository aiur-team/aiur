# OCC-8 decision revision contract

**Status:** Implemented in ticket #985

**Builds on:**
[`03-occ-1-decision-contract.md`](./03-occ-1-decision-contract.md) and OCC-3's
durable answer-delivery contract. OCC-2 may project the follow-up attention but
is not an OCC-8 correctness dependency.

This contract defines what a revision means after an operator or supervising
agent has already answered a Decision. A revision is a new append-only action,
not a rewrite of the original answer and not evidence that any prior effect was
reversed.

## Ownership

- `Aiur.DecisionStore` is the only revision writer and durable outbox owner.
- OCC-3 owns answer normalization, action correlation, queue attempts,
  acknowledgement, resolution, and retry settlement.
- OCC-8 adds revision validation, causal links, target revalidation, corrective
  message rendering, the no-longer-applicable outcome, and its durable blocking
  follow-up.
- `Aiur.DecisionAttention` and `Aiur.AlertFeed` project reminders. They never
  own revision or follow-up lifecycle state.
- OCC-4 and OCC-7 call the same store operation and render/encode its result;
  they do not dispatch directly or reimplement conflict rules.

## Three independent axes

| Axis | Meaning | Revision behavior |
|---|---|---|
| Request version | The current question/context version | A revision must target the current version; it does not increment this axis. |
| Revision sequence | Ordered corrections to the active answer action | Each accepted correction advances this sequence exactly once. |
| Action identity | Stable idempotency/correlation identity for one answer or revision | Each accepted revision receives a new action ID and links the action it supersedes. |

The original request versions, answers, attempts, acknowledgement, and
resolution facts remain byte-for-byte reconstructable from the audit after a
revision becomes current.

## Submission

A revision mutation carries:

- the Decision ID and current request version;
- the expected active action ID and revision sequence;
- a stable client idempotency key;
- exactly one replacement option or custom response;
- a required reason;
- a trusted actor supplied by the authenticated caller.

The answer, actor, idempotency key, and free text use OCC-3's existing bounds,
control-character checks, redaction, and option validation. The store derives
the revision action ID in the Decision scope. A caller cannot choose the
canonical action ID, acceptance timestamp, ticket, or actor provenance.

## Result vocabulary

| Result | Meaning | Safe caller presentation |
|---|---|---|
| `rejected` | Validation or optimistic-correlation checks failed; nothing was appended or dispatched. | Refresh and show the current request/revision/action correlation. |
| `recorded` | The revision intent is durable; target inspection or dispatch is pending/retrying. | “Revision recorded; follow-up pending.” |
| `dispatched` | A correlated corrective follow-up was accepted by the queue path. | “Revision recorded; follow-up queued.” |
| `no_longer_applicable` | A fresh target lookup found the ticket missing/terminal, or a correlated target report later established non-applicability. | “Target no longer active; operator follow-up required.” |

Queue delivery, consumption, agent turn completion, branch changes, and elapsed
time do not change `recorded` into “rolled back,” “reverted,” “undone,” or
“applied.” OCC-3 acknowledgement/resolution remain separate facts.

## Acceptance and conflict rules

- The current request version, active action ID, and revision sequence must all
  match inside the serialized store mutation.
- An exact retry of the same client token and normalized content returns the
  existing revision action without another append or queue item.
- Reusing the token with different content fails closed.
- Two submissions racing the same active action have one winner. The loser
  receives the new current correlation and appends nothing.
- Unknown/cross-ticket actions, stale request versions, and already-superseded
  actions append nothing and cause no side effect.

## Persist-before-dispatch ordering

For an accepted revision:

1. Normalize and compare the mutation against the current projection.
2. Append and fsync the revision intent under its new action ID.
3. Replace the current projection.
4. Return the durable `recorded` result and schedule reconciliation.
5. Refresh target state through the existing tracker/dispatcher seam.
6. Append applicability/dispatch facts and only then publish their live
   notifications.

No tracker call, orchestrator wake, queue insertion, attention, generic event,
or PubSub broadcast may precede step 2.

## Target matrix

| Fresh observation | Revision outcome | Dispatch behavior |
|---|---|---|
| Ticket exists and is non-terminal; target running | Remains applicable | Send one correlated corrective message. |
| Ticket exists and is non-terminal; target paused/deactivated | Remains applicable | Use OCC-3/OperatorMessages reactivation and capacity gates, then send once. |
| Ticket exists and is non-terminal; no current process/capacity | Pending/retryable | Keep the same revision action; do not call it un-applicable. |
| Tracker fetch/control/queue error or timeout | Pending/failed under OCC-3 retry rules | Retry the same action with attempt-specific correlation. |
| Ticket is freshly missing or terminal | `no_longer_applicable` | Do not queue the corrective message; create the stable blocking follow-up. |

The refresh happens after revision persistence so a target that becomes
terminal during submission produces an auditable intent followed by a truthful
no-longer-applicable outcome.

## Corrective follow-up

An applicable target receives a bounded message through OCC-3's correlated
`OperatorMessages` path. It identifies the Decision, request version, prior and
new action IDs, actor, replacement answer, and revision reason. It tells the
agent to inspect current state before following the new direction and explicitly
states that earlier instructions may already have taken effect.

The message never claims automatic rollback, retraction, revert, undo, or
successful application. Retries preserve the same logical revision action and
use OCC-3's attempt-specific queue handles.

## No-longer-applicable blocking follow-up

Before opening a reminder, the parent revision audit records a deterministic
`follow_up_required` fact and slug derived from the revision action.
Reconciliation opens that stable `DecisionAttention` question only after the
fact is durable.

The follow-up asks what should happen now that the target cannot automatically
apply the revision. It links the parent Decision, request version, and revision
action without claiming the original answer was reversed. Replaying or
restarting reuses the same attention slug, so one active reminder is re-asked
rather than duplicated.

An OCC-2 adapter may expose the attention in the Decision inbox, but that is a
projection rather than an OCC-8 storage dependency. Handling or superseding the
follow-up appends a canonical parent event before the reminder is resolved; the
required and handled facts remain append-only.

## Recovery and notification

- A durable revision intent without a terminal applicability/dispatch fact is
  recoverable work for OCC-3 reconciliation.
- A durable no-longer-applicable outcome plus open follow-up fact without its
  reminder projection is recoverable work for the asynchronous revision
  dispatcher.
- Queue and alert retries use stable logical identities; individual attempts
  may have distinct transport handles.
- `Aiur.Events.Exchange`, Decision PubSub, attentions, and alerts are emitted
  only after the event they describe is durable. Consumers recover missed live
  notifications by rereading `DecisionStore`.
- Reconciliation runs outside `DecisionStore` calls so attention/alert
  projection cannot block the serialized writer.

## Downstream handoff

- **OCC-4:** expose Revise Decision controls, show actor/reason/current action,
  and render the result vocabulary and immutable timeline.
- **OCC-6:** read original/revision/follow-up facts from the canonical
  projection; do not infer revision success from delivery.
- **OCC-7:** authorize callers, inject the trusted actor, and delegate to the
  same revision operation with its stale/idempotency contract.
- **OCC-9:** derive revision/dispatch/ack durations from canonical timestamps.

No downstream consumer calls `OperatorMessages` or opens/resolves the reminder
as a substitute for the revision application service.

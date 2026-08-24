# Commands

A Command is a durable issue an agent flags for the Executor.

## What the Commands page shows

The Commands page is dashboard `/decisions` and CLI `aiur commands`.

<img src="/images/dashboard/commands-dark.png" alt="Desktop Commands decision inbox populated with synthetic decisions">

| Field | Meaning |
| --- | --- |
| Ticket and source | Work and agent that raised the Command. |
| Urgency and authority | How quickly it matters and who may answer. |
| Options and recommendation | Bounded outcomes with the agent's preferred choice. |
| Lifecycle | Open, answered, delivered, acknowledged, resolved, or superseded. |

## Executor responses

| Response | Result |
| --- | --- |
| Answer directly | Pick an option or write a bounded response and send it to the agent. |
| Defer | Leave the Command for a designated Executor agent to investigate and decide. |
| Revise | Append a corrected action without rewriting the original record. |

## Authority and attention signals

Agents classify the action, not the subsystem around it. Routine,
reversible operational choices should use `supervisor_allowed`; irreversible
actions, spend, external publication, and product direction remain
`human_required`. The Executor can answer only a Command that declares
`supervisor_allowed` or `supervisor_preferred` together with `reversible`.

Classification is consequence-based and defaults delegable: a Command that
omits `authority`/`reversibility` is treated as `supervisor_allowed` +
`reversible`, so reversible engineering calls reach the Executor instead of
parking an agent until an operator appears. Known Command types carry an
explicit policy (`src/lib/aiur/decision_command_type.ex`): a **re-review
request** (`kind: "rework_review"`) classifies `supervisor_preferred` +
`reversible`, a **PR/ticket sequencing** question (`kind: "sequencing"`)
classifies `supervisor_allowed` + `reversible`, and pre-OCC
`legacy_attention` projections stay `human_required`. Because omission
defaults to the Executor floor, a Command that is genuinely irreversible,
involves spend or external publication, or changes product direction must
declare `authority: human_required` (and the matching `reversibility`)
explicitly.

Aiur warns when a human-required Command is reversible and all of its
options are low-risk. It also raises attention when a blocking Command remains
unanswered for a day, or when an Executor-unanswerable Command expires without a
decision. These signals expose stale context and upstream misclassification;
they do not weaken the answer-authorization floor.

Deferred Commands remain visible in the Open and Blocking dashboard counts until they are answered or retired. Their cards show both the deferred lifecycle and the age of the outstanding Command.

## Durability

| Contract | Why it matters |
| --- | --- |
| ID and version | Scope every answer and revision. |
| Action ID | Correlates delivery, acknowledgement, and resolution. |
| Append-only revision | Preserves what the Executor previously decided. |
| Shared projection | Dashboard and CLI read the same durable record. |

See [Message Bus decisions](/concepts/message-bus#commands-and-decisions) for the event path.

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

Deferred Commands remain visible in the Open and Blocking dashboard counts until they are answered or retired. Their cards show both the deferred lifecycle and the age of the outstanding Command.

## Durability

| Contract | Why it matters |
| --- | --- |
| ID and version | Scope every answer and revision. |
| Action ID | Correlates delivery, acknowledgement, and resolution. |
| Append-only revision | Preserves what the Executor previously decided. |
| Shared projection | Dashboard and CLI read the same durable record. |

See [Message Bus decisions](/concepts/message-bus#commands-and-decisions) for the event path.

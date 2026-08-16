# Commands

Commands gives the Executor **one place to track every issue an agent flags**. An agent that hits a choice it must not make alone records a durable decision request and stops. That request lands here, and from here the Executor either writes a response directly and sends it back to the agent, or defers it to an Executor agent to decide.

Commands is the dashboard's `/decisions` page. Its CLI counterpart is `aiur commands`.

<img src="/images/dashboard/commands-dark.png" alt="Desktop Commands page with synthetic decisions in several lifecycle states">

::: info Example data
Every screenshot in this section was captured from the shipped dashboard against an isolated fixture. Tickets, agents, decisions, and links are synthetic.
:::

## Why a durable inbox

An agent blocked on a question has three bad options: guess, stall silently, or spam an alert nobody reads. Commands is the fourth. The request is durable before it appears in any browser, it carries an ID and a version that scope every later action, and it stays visible until it is resolved.

That also means an Executor never has to hold a queue of pending questions in their head, or in a chat scrollback.

## The inbox

Decisions sort by blocking status, then urgency, then age. Filters separate open, blocking, undelivered, supervising-Executor, resolved, and superseded records. Selecting a card opens its stable `/decisions/:decision_id` detail URL.

A card shows the ticket, source agent, urgency, authority, recommended option, and current lifecycle. The expanded detail adds full context, consequence of delay, options, artifacts, lifecycle timing, and the durable action controls.

## Responding

When writes are enabled a human Executor can:

- **Answer** with one of the offered options, or with a bounded custom response.
- **Retry delivery** after a recorded answer hits a retryable delivery failure.
- **Revise** a recorded answer. Revisions are append-only corrections; the original action stays in history.
- **Handle a revision follow-up** when a correction can no longer reach an active target.
- **Defer** or **dismiss** a decision that does not need an answer now.

A supervising Executor agent can answer or escalate through the separately authenticated machine API, or from the terminal:

```bash
aiur executor-answer dec_123 --expected-version 1 --option morning \
  --rationale "Lowest risk" --idempotency-key run-1
```

`--expected-version` is an optimistic-concurrency guard, so a stale answer is rejected rather than overwriting a newer one, and `--idempotency-key` makes a retried command safe. `aiur executor-escalate` hands the decision back to the human instead of answering it.

## Lifecycle

The stepper is a compact view over two canonical axes, decision state and delivery state. It never invents a transition.

| Display state | What it means |
| --- | --- |
| **Recorded** | The request is durable and still awaits an answer. |
| **Dispatch pending** | An answer is durable; delivery is queued or not yet confirmed. |
| **Delivered** | The active answer reached the target agent. |
| **Acknowledged** | The target emitted the correlated acknowledgement event. |
| **Resolved** | The target emitted the correlated terminal resolution event. |
| **Delivery failed** | Delivery failed and may be retryable; the answer remains durable. |
| **Superseded** | A newer append-only revision replaced an earlier action. |

The **target agent**, not the browser, records `decision.acknowledged` and `decision.resolved` after consuming and completing the active answer. A green button in a browser is not evidence the agent acted; the acknowledgement event is.

## History

History is projected from the append-only decision audit. It attributes human Executor, supervising-Executor, ticket-agent, and system facts only when the canonical record identifies them. Dispatch, acknowledgement, revision, and follow-up results remain visible after the active card changes.

## Reading it from the terminal

```bash
aiur commands --filter blocking --json
```

`--filter` accepts `all`, `open`, `blocking`, or `resolved`. `--ticket` and `--search` narrow an `all` query. `--cursor` and `--limit` page the result. See the [CLI](/reference/cli#decisions-executor-events-and-findings) for the full set.

Answering a ticket comment does **not** unblock an agent waiting on a decision. The durable record is what the agent consumes; see [Message Bus](/concepts/message-bus#decisions) for the delivery path.

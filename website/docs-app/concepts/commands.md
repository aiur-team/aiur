# Commands

A Command is a durable issue an agent flags for the Executor. Agents raise them when they need a decision, hit a blocker that only the Executor can resolve, or want attention on something.

## What the Commands page shows

The Commands page (dashboard `/decisions`, or `aiur commands` on the CLI) gives the Executor one place to track every issue agents flag. Each Command carries the ticket, the source agent, urgency, authority, recommended option, and its lifecycle state.

<img src="/images/dashboard/commands-dark.png" alt="Desktop Commands decision inbox populated with synthetic decisions">

From the Commands page the Executor has two responses:

- **Answer directly.** Write a response and send it back to the agent, either as an option pick or a bounded custom response.
- **Defer to an Executor agent.** Leave the Command for a designated Executor agent to investigate and decide.

## Why Commands are durable

A Command is recorded before it appears anywhere in the dashboard, and its ID and version scope every later action. An answer, a revision, and a delivery all reference the same durable record, so the Executor and the agent share one source of truth instead of a chat log. See [Message Bus](/concepts/message-bus) for the event path that carries these records.

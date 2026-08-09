# Coordination and events

Aiur coordinates work at two levels: tracker state determines which tickets are eligible to run, while durable events carry facts and dependencies between active tickets and agents.

## The event path

Agents publish scoped events onto a topic exchange. A ticket event is named under `ticket.<issue>.agent.<event>`, and subscribers use AMQP topic patterns: `*` matches one segment and `#` matches zero or more.

```text
ticket.142.agent.progress.docs
ticket.142.agent.decision.requested
ticket.142.branch.push
```

Events are signals, not shared mutable state. A consumer that needs code or a durable decision follows the event’s validated reference or correlation fields and reads the owning source of truth.

## Dependencies

Declaring another issue as a blocker creates a native issue dependency and subscribes the blocked ticket to relevant lifecycle and branch events. The blocked agent should keep independent preparation moving, but must not duplicate blocker-owned code.

When the blocker pushes, the dependent agent inspects the exact validated ref in the event payload. If the needed API landed, it stacks its branch on that ref and removes provisional integration code. A guessed branch name is never a substitute for the event payload.

## Decisions

A decision request is durable before it appears in the Control Center. Its ID and version scope every later action:

1. A ticket agent records a request.
2. A human or authorized supervising Executor records an answer.
3. Aiur dispatches the correlated action to the target.
4. The target records acknowledgement and resolution with the delivered decision ID, action ID, and expected version.

Revisions append a new action rather than rewriting the original. If a target can no longer accept the correction, Aiur records the explicit follow-up state.

## Progress and attentions

Progress events are estimates for the Executor’s fleet view; they do not advance tracker state. Attention events identify a concrete condition that needs review or action and should be resolved when that condition clears.

Use events for cross-ticket coordination that another agent may consume. Use alerts for immediate Executor-facing notification. See [Executor Control Center](/guide/executor-control-center) for the browser projections of these facts.

## GitHub listener automation

Aiur observes GitHub through a narrow repository-events firehose and targeted polling. The firehose publishes default-branch pushes, opened pull requests, and merged pull requests. It drops issue events. Ticket-branch pushes are polled separately with `git ls-remote`; comments and review threads are polled for trusted review-driven wakeups; and CI is polled while a ticket is in `agent:ci-wait`.

Comment commands and review-driven rework are accepted only from the configured trusted accounts or the resolved CODEOWNERS set. Aiur refreshes CODEOWNERS on the configured cadence and surfaces a safe degraded-trust alert if it cannot resolve the file. The bot identity is excluded to prevent self-triggered loops.

The most useful live topics are `ticket.<id>.agent.*` for agent progress, decisions, alerts, and explicit blockers; `ticket.<id>.branch.push` for validated branch refs; and Executor subscriptions under `executor.#`. Treat a branch push as evidence to inspect, not as an unblock signal. CI and review facts are ultimately tracker-derived polling results, even when their projections appear live in the dashboard.

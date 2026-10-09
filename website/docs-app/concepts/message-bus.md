# Message Bus

Aiur uses a shared topic exchange to signal coordination between tickets, agents, and the Executor.

## Topic shape

| Scope | Pattern | Example |
| --- | --- | --- |
| Ticket | `ticket.<id>.<surface>.<verb>` | `ticket.142.agent.progress` |
| Base branch | `system.<branch>.<surface>.<verb>` | `system.main.branch.push` |
| One segment | `*` | `ticket.*.branch.push` |
| Any remaining segments | `#` | `ticket.142.#` |

Events are signals; consumers follow validated references or correlation fields to the durable source of truth.

## What survives a restart

| Class | Topics | After a restart or disconnect |
| --- | --- | --- |
| Live | GitHub, CI, PR and branch events (`ticket.<id>.pr.*`, `ticket.<id>.ci.*`, `ticket.<id>.branch.push`, `ticket.<id>.issue.commented`, `system.<branch>.branch.push`) | Not replayed. Consumers re-read GitHub or the tracker. |
| Logged | Events an agent emits for its own ticket (`ticket.<id>.agent.*`) | Written to the ticket's event log asynchronously, on a best-effort basis, only with a trusted ticket identity and while its log writer exists. Own emissions are not replayed on the agent's next turn. |
| Ledgered | Alerts and attentions emitted through the alert system (`ticket.<id>.agent.attention.*`, `system.*` alerts) | Kept in the alert feed; the ledger does not replay them as events. |
| Journaled | Executor stream (`executor.*`) and Command lifecycle | Written before delivery. The Executor stream replays from its cursor; Command records remain in their owning store. |

These classes describe the existing persistence paths; a topic name alone does not guarantee durability.
Logged events can be recovered by bootstrap when they match a subscription and follow its cursor, but bootstrap excludes own-emission (`self`) markers.

Event IDs are unique per instance and survive restarts. They increase in the order they are assigned, may have gaps, and do not describe delivery order; use them to deduplicate, not to sort deliveries.

Wakes for non-Executor topics that arrive while the Executor listener is down are not replayed; read `aiur status` and the tracker after a restart.

## Agent events

| Name | Operator meaning |
| --- | --- |
| `progress` / `progress.checkin` | Current completion estimate for the Units progress bar. |
| `progress.<slug>` | A named milestone inside the ticket. |
| `decision.<slug>` | A ticket-level decision or design choice. |
| `decision.acknowledged` | The target began applying a durable Executor answer. |
| `decision.resolved` | The target finished the correlated answer. |
| `blocked` | A named integration point cannot proceed. |
| `unblocked` | A real dependency or declared temporary stub released work. |
| `attention.<slug>` | A concrete condition needs Executor attention. |
| `attention.resolved` | The named attention cleared. |
| `pause.request` | The agent asks to pause at a safe checkpoint. |
| `custom.<slug>` | Ticket-specific coordination outside the standard families. |

## Tracker and repository events

| Topic | Meaning |
| --- | --- |
| `ticket.<id>.branch.push` | A validated ticket branch ref and commit changed. |
| `system.<branch>.branch.push` | The integration branch moved. |
| `system.capabilities.changed` | A stored capability report changed; payload contains only `revision` and `boot_id`. Refetch the authenticated report. Published on the first report after boot, never on unchanged ticks; does not wake the Executor. In-node consumers receive `{:capabilities_changed, revision}` on PubSub topic `capabilities`. |
| `system.queue.<queue_id>.progress` | A queue crossed a progress milestone. |
| `system.build_order.<root>.progress` | A Build Order crossed a progress milestone. |
| `ticket.<id>.pr.opened` | The ticket's pull request opened. |
| `ticket.<id>.pr.merged` | The ticket's pull request merged. |
| `ticket.<id>.issue.commented` | A trusted issue comment arrived. |
| `ticket.<id>.pr.review_comment` | A trusted PR review comment or thread arrived. |
| `ticket.<id>.ci.passed` | Terminal CI passed. |
| `ticket.<id>.ci.failed` | Terminal CI failed. |

Progress milestones use current, resolved or partially resolved facts. Only the highest crossed threshold (25%, 50%, 75% or 100%) is announced per observation.

Durable latches prevent repeats within a scope generation after restart; unreadable or unwritable latch storage suppresses milestones. The events carry `milestone`, `percent` and `generation` attributes.

Internal consumers can read `Aiur.BuildProgress.facts/1` for all scopes (`:all`) or one scope.

`subscribe/0` subscribes to Phoenix PubSub topic `build_progress`, carrying `{:build_progress_changed, fact}` when percent, resolution, freshness or generation changes, including decreases.

Facts remain readable and signals continue when milestone storage is unavailable. This internal signal is separate from the topic exchange.

## Automatic subscriptions

Agents automatically subscribe to events relevant to their ticket, pull request, base branch, and declared blockers.

| Subscription | Why it is automatic |
| --- | --- |
| Own issue comments | Delivers operator direction. |
| Own PR reviews | Routes trusted rework feedback. |
| Own terminal CI | Moves between repair, CI wait, and human review. |
| Base-branch pushes | Warns when the integration target moves. |
| Blocker lifecycle and branch pushes | Resumes the dependent ticket on explicit readiness. |

Dispatch also creates the standard blocker subscriptions from hydrated native dependencies before spawning a worker, without posting the dependency again.

They use `blocker:auto` on the dependent and `blockee:auto` on the blocker, just like `aiur_declare_blocker`. An optimistic dispatch declines if binding fails, so the worker cannot start without hearing blocker pushes.

Manual `aiur_subscribe` is for additional watch cases, not for the standard ticket lifecycle.

## Manual subscription scope

Every manual `aiur_subscribe` pattern must start with one literal ticket identifier.

| Request | Result |
| --- | --- |
| `ticket.142.#` or `ticket.314.branch.push` | Accepted; one named ticket. |
| `ticket.*.branch.push` | Refused; fleet-wide ticket patterns are out of scope. |
| `executor.*` or `system.*` | Refused; control-plane topics are not agent-subscribable. |
| Bare `*` or `#` | Refused. |

Automatic own-ticket, blocker, CI, review, and base-branch subscriptions are trusted internal wiring and keep their purpose-specific topics. The Executor control-plane subscription under `executor.#` is distinct from this agent policy.

## Queue transitions

`ticket.<id>.queue.<verb>` publishes live hints after a saved transition, with
verbs `promoted`, `withdrawn`, `held`, `released`, `overridden`, and `removed`.
Payloads contain only `ticket`, `queue_id`, and `cause` references and attributes
(plus the bus envelope). An operator removal carries cause `operator`.

Consumers re-read queue state; these topics are not bound to the Executor by
default and are not replayed after a daemon restart. Publication failures are
logged without retry.

## Queue attentions

Queue attentions add two default Executor bindings: `ticket.*.queue.attention.#`
(`attention:auto`) and `system.queue.attention.#` (`dispatch:auto`). Both include
the `.resolved` events that clear an attention.

Queue latches survive restarts; the attention API retains failed durable
emissions for retry by reconciliation. Queue bus payloads carry
allowlisted references and attributes; human-readable copy stays in the local alert feed.

## Dependencies

| Step | Contract |
| --- | --- |
| Declare | `aiur_declare_blocker(N)` records the native issue dependency and subscriptions. |
| Prepare | The blocked agent keeps independent work moving without duplicating blocker-owned code. |
| Push | The blocker publishes the promised code before announcing readiness. |
| Signal | `ticket.N.agent.unblocked` carries the validated ref and commit. |
| Integrate | The dependent agent fetches that exact ref, inspects it, and removes provisional code. |

A branch push alone never resumes a dependent ticket. Before the blocker merges, readiness comes from an explicit validated `ticket.<id>.agent.unblocked` event; reconciling the blocker as merged can also clear the dependency pause.

## Commands and decisions

| Step | Durable correlation |
| --- | --- |
| Request | The Command records an ID and expected version before projection. |
| Answer | A human or authorized Executor records one correlated action. |
| Delivery | Aiur sends that action to the target. |
| Acknowledge | The target repeats the decision ID, action ID, and expected version. |
| Resolve | The target repeats the same fields after finishing. |
| Revise | A new action is appended instead of rewriting history. |

See [Commands](/concepts/commands) for the Executor view.

## GitHub observation

| Source | Events it supplies |
| --- | --- |
| Repository events | Default-branch pushes and opened or merged PRs. |
| Ticket-branch watch | Validated ticket ref changes. |
| Trusted comment polling | Issue comments, PR comments, reviews, and threads. |
| CI polling | Terminal results for `agent:ci-wait` tickets. |

See [GitHub](/apis/github) for polling, rate budgets, and optional webhook setup.

## Where a new fact goes

- A coordination fact with an identity or routing information goes to the topic exchange.
- A local "re-read this state" notification goes to PubSub with a version. Consumers re-read the owning store; the notification is not the source of truth.
- Persist first, publish with the durable event ID, then notify local subscribers. [Commands](/concepts/commands) follow this order.
- Bridges run from the exchange to PubSub only; do not turn a local notification into a coordination fact.

Signals, not state — see the [opening rule](#topic-shape).

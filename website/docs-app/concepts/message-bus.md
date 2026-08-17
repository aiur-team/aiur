# Message Bus

Aiur uses a shared topic exchange for durable coordination between tickets, agents, and the Executor.

## Topic shape

| Scope | Pattern | Example |
| --- | --- | --- |
| Ticket | `ticket.<id>.<surface>.<verb>` | `ticket.142.agent.progress` |
| Base branch | `system.<branch>.<surface>.<verb>` | `system.main.branch.push` |
| One segment | `*` | `ticket.*.branch.push` |
| Any remaining segments | `#` | `ticket.142.#` |

Events are signals; consumers follow validated references or correlation fields to the durable source of truth.

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
| `ticket.<id>.pr.opened` | The ticket's pull request opened. |
| `ticket.<id>.pr.merged` | The ticket's pull request merged. |
| `ticket.<id>.issue.commented` | A trusted issue comment arrived. |
| `ticket.<id>.pr.review_comment` | A trusted PR review comment or thread arrived. |
| `ticket.<id>.ci.passed` | Terminal CI passed. |
| `ticket.<id>.ci.failed` | Terminal CI failed. |

## Automatic subscriptions

Agents automatically subscribe to events relevant to their ticket, pull request, base branch, and declared blockers.

| Subscription | Why it is automatic |
| --- | --- |
| Own issue comments | Delivers operator direction. |
| Own PR reviews | Routes trusted rework feedback. |
| Own terminal CI | Moves between repair, CI wait, and human review. |
| Base-branch pushes | Warns when the integration target moves. |
| Blocker lifecycle and branch pushes | Resumes the dependent ticket on explicit readiness. |

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

## Dependencies

| Step | Contract |
| --- | --- |
| Declare | `aiur_declare_blocker(N)` records the native issue dependency and subscriptions. |
| Prepare | The blocked agent keeps independent work moving without duplicating blocker-owned code. |
| Push | The blocker publishes the promised code before announcing readiness. |
| Signal | `ticket.N.agent.unblocked` carries the validated ref and commit. |
| Integrate | The dependent agent fetches that exact ref, inspects it, and removes provisional code. |

A branch push is evidence to inspect, not an unblock signal by itself.

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

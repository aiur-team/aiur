# Message Bus

Aiur coordinates work at two levels. Tracker state decides which tickets are eligible to run. The **Message Bus** carries facts and dependencies between tickets, agents, and the Executor while they run.

Events are signals, not shared mutable state. A consumer that needs code or a durable decision follows the event's validated reference or correlation fields and reads the owning source of truth.

## Topics

Publishers emit onto a topic exchange with AMQP 0-9-1 semantics: `*` matches exactly one segment, `#` matches zero or more.

```text
ticket.142.agent.progress.docs
ticket.142.branch.push
system.main.branch.push
executor.decision.requested
```

Three namespaces:

| Namespace | Shape | Scope |
| --- | --- | --- |
| `ticket.` | `ticket.<identifier>.<surface>.<verb>` | One ticket. |
| `system.` | `system.<branch\|subsystem>.<...>` | Fleet-wide or repository-wide. |
| `executor.` | `executor.<...>` | The Executor's durable stream. |

Patterns are validated before they bind. An empty pattern, a leading or trailing `.`, or an empty segment is rejected. The `executor.` namespace additionally refuses any publish whose source is GitHub.

## Agents subscribe automatically

An agent does not have to subscribe to work normally. Two automatic paths cover the cases that matter, and they are the only automatic ones.

### Its own ticket

Attached when the agent starts, and re-attached on a comment wake or a CI wake:

| Topic | Why |
| --- | --- |
| `ticket.<self>.issue.commented` | Comments on its own issue. |
| `ticket.<self>.pr.review_comment` | Review comments and review threads on its own PR. |
| `ticket.<self>.ci.passed` | Terminal CI pass. |
| `ticket.<self>.ci.failed` | Terminal CI failure. |
| `ticket.<self>.operator.progress_request` | The periodic check-in ping. |
| `system.<base-branch>.branch.push` | The base branch moved under it. |

This set is deliberately narrow rather than a blanket `ticket.<self>.#`. An agent is **not** auto-subscribed to its own `branch.push`, `pr.opened`, or `pr.merged`; those are consumed by the orchestrator, which owns the resulting state transition. Anything outside the table needs an explicit `aiur_subscribe`.

### Its blockers

Declaring a blocker creates the native tracker dependency **and** binds both directions, automatically and idempotently. It also happens the other way round: the orchestrator's issue poll binds the same pair when it observes a new `blocked_by` edge it did not see declared.

| Direction | Topics |
| --- | --- |
| Blocked agent watches the blocker | `ticket.<blocker>.branch.push`, `.branch.force-push`, `.pr.opened`, `.pr.merged`, `.agent.decision.*`, `.agent.blocked`, `.agent.unblocked`, `.agent.attention.*`, `.issue.commented` |
| Blocker watches the blocked agent | `ticket.<blockee>.agent.blocked`, `.agent.unblocked` |

Removing the dependency edge removes the automatic bindings. A manually added binding on the same topic survives, because removal is scoped by the reason it was created with.

## Events an agent emits

`emit_event` publishes to `ticket.<id>.agent.<name>` against a closed allowlist.

| Name | Meaning |
| --- | --- |
| `progress` | A 1-of-10 completion estimate in `payload.percent`. Capped at two bare `progress` emits per turn. |
| `progress.<slug>` | A named milestone, such as `progress.tests-green`. |
| `decision.<slug>` | An architectural choice broadcast to interested tickets. |
| `blocked` | A block that cannot be stubbed around. |
| `unblocked` | Readiness. This is what resumes a waiting dependent. |
| `attention.<slug>` | Opens an attention that the Executor should clear. |
| `attention.resolved` | Closes one, matched by `payload.slug`. |
| `pause.request` | Asks to pause at the next safe checkpoint. |
| `custom.<slug>` | Anything else. |

`decision.requested` is special. It never reaches the exchange: it is intercepted and routed into the durable decision store, which is what makes it appear in [Commands](/concepts/commands). The generic publisher rejects the name outright. `decision.acknowledged` and `decision.resolved` are likewise emitted by the decision store on the agent's behalf, and require a `decision_id`, `action_id`, and `expected_version`.

Milestone **alerts** raised with `emit_alert` are also prefixed into `ticket.<id>.agent.<name>` and published to the same exchange. A subscriber to `ticket.42.agent.#` therefore receives alerts as well as events.

## Events the system emits

Lifecycle facts about a ticket:

| Topic | Published when |
| --- | --- |
| `ticket.<id>.branch.push` | A validated push to that ticket's branch. |
| `ticket.<id>.pr.opened` | Its pull request opens. |
| `ticket.<id>.pr.merged` | Its pull request merges. |
| `ticket.<id>.issue.commented` | A comment lands on the issue. |
| `ticket.<id>.pr.review_comment` | A review comment or review thread lands. |
| `ticket.<id>.ci.passed`, `.ci.failed`, `.ci.rewake` | Terminal CI outcome, and the recovery wake. |
| `ticket.<id>.issue.label.added.agent.<state>` | An `agent:*` label transition. |
| `ticket.<id>.agent.paused`, `.agent.unpaused` | Tracker pause flips. |
| `ticket.<id>.merge.unauthorized_merger`, `.merge.attribution_check_failed` | Merge-policy violations. |
| `ticket.<id>.workspace.provisioning_incomplete` | Workspace provisioning did not finish. |

The orchestrator also publishes into the `agent.attention.*` and `agent.error.*` families, so those are not agent-exclusive: `attention.state_divergence`, `attention.waiting_for_human`, `attention.error-<cause>`, `attention.unsupported_model`, `agent.error.tokens_exhausted`, `agent.usage_limit_exhausted`, `agent.thrash_circuit_open`, `agent.retry_exhausted`, and `agent.auto_resume_exhausted`.

Fleet and infrastructure facts land under `system.`:

| Family | Examples |
| --- | --- |
| Dispatch | `system.dispatch.capacity_starved[.resolved]`, `.pr_anchored_held`, `.prewarm_blocked[.resolved]`, `.todo_capacity_exceeded` |
| Capacity | `system.fleet.capacity.backoff`, `.resumed`, `.starved[.resolved]` |
| Tracker auth | `system.tracker.auth_preflight_failed[.resolved]` |
| GitHub App token | `system.github_app_token.refresh_failed`, `.refresh_recovered`, `.permission_violation`, `.identity_mismatch` |
| GitHub API | `system.github.connectivity_lost`, `system.github.quota.<resource>.<threshold>` |
| Webhooks | `system.github_webhook.secret_missing` |
| Supervision | `system.supervision.degraded[.resolved]` |
| Branches | `system.<branch>.branch.push` |

`system.` topics are not retained per issue, so they are live-only and cannot be replayed.

## Delivery

- **Fanout.** Publishing sends to every matching binding. There is no acknowledgement and no backpressure.
- **Ordering.** Every event gets a monotonic ID at publish time. Durable events reserve their ID up front.
- **Deduplication.** A subscriber drops any event whose ID is at or below its cursor, so redelivery is safe. A one-hour publish-side dedup window suppresses repeats keyed on the event.
- **Replay.** Every `ticket.` event is appended to the publisher's per-issue log. On the first turn after a start or restart, an agent reads each subscribed publisher's log from its cursor, filters by pattern, deduplicates, and receives one batched digest. A fresh binding replays from the point it was created, not from the beginning of time.
- **Turn boundary.** The default is a between-turns digest. Only blocker-critical topics drain mid-turn: a direct blocker's `branch.push`, `branch.force-push`, `agent.unblocked`, and `agent.decision.<slug>`.
- **Trust filtering.** GitHub-sourced events must carry a trusted author, resolved from the configured accounts or CODEOWNERS. Unknown sources fail closed. CI events are exempt. Filtered events stay in the log and on the dashboard; they simply do not wake an agent.
- **Self-loop suppression.** The bot identity's own activity is dropped so a run cannot trigger itself. `pr.merged` is the deliberate exception.
- **Debounce.** Repeated `blocked` and `unblocked` flips coalesce over `events.block_state_debounce_seconds`.

The Agent Workpad comment is filtered from event polling, so an agent's own workpad edits never wake agents or spam digests.

## Dependencies

Declaring another issue as a blocker creates a native issue dependency and the subscriptions above. The blocked agent should keep independent preparation moving, but must not duplicate blocker-owned code.

When the blocker pushes, the dependent agent inspects the exact validated ref in the event payload. If the needed API landed, it stacks its branch on that ref and removes provisional integration code. A guessed branch name is never a substitute for the event payload, and a branch push is evidence to inspect rather than an unblock signal.

## Decisions

A decision request is durable before it appears in [Commands](/concepts/commands). Its ID and version scope every later action:

1. A ticket agent records a request.
2. A human or authorized supervising Executor records an answer.
3. Aiur dispatches the correlated action to the target.
4. The target records acknowledgement and resolution with the delivered decision ID, action ID, and expected version.

Revisions append a new action rather than rewriting the original. If a target can no longer accept the correction, Aiur records the explicit follow-up state.

Progress events are estimates for the Executor's fleet view and do not advance tracker state. Attention events identify a concrete condition that needs review and should be resolved when that condition clears.

## The Executor's half

The Executor binds to `executor.#` by default and gets a durable stream rather than a live-only one.

| Command | Does |
| --- | --- |
| `aiur executor-listen [--topic <pattern>]` | Persists the subscription, replays from the saved cursor, then streams live JSON lines. |
| `aiur executor-emit <topic> --payload <json>` | Publishes on an `executor.` topic. Other namespaces are rejected. |
| `aiur executor-subscribe`, `-unsubscribe`, `-subscriptions` | Manage persistent bindings. |

Aiur itself publishes `executor.decision.requested` and `executor.decision.deferred`.

## Alerts versus events

Use an **event** for cross-ticket coordination another agent may consume. Use an **alert** for immediate Executor-facing notification. Alerts are defined in the checked-in `.aiur/alerts` file, keyed by an event-topic glob pattern, each carrying a `message` and an optional `sound` list. When two patterns match, the more literal one wins.

## How Aiur observes GitHub

The Message Bus is fed by a narrow repository-events firehose plus targeted polling. The firehose publishes default-branch pushes, opened pull requests, and merged pull requests, and drops issue events. Ticket-branch pushes are polled separately with `git ls-remote`. Comments and review threads are polled for trusted review-driven wakeups. CI is polled while a ticket sits in `agent:ci-wait`.

Comment commands and review-driven rework are accepted only from the configured trusted accounts or the resolved CODEOWNERS set. Aiur refreshes CODEOWNERS on the configured cadence and raises a degraded-trust alert if it cannot resolve the file. CI and review facts are ultimately tracker-derived polling results, even when their projections look live in the [Dashboard](/guide/executor-control-center).

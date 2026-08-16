# Aiur Events — Taxonomy

## Topic structure

Every event topic is a dot-separated string. Format:

```
ticket.<id>.<surface>.<verb>      # ticket-scoped events
system.<branch>.<surface>.<verb>  # repo-wide events (e.g., default-branch push)
```

You bind patterns to topics. The two wildcards (AMQP topic-exchange semantics):

- `*` — exactly one segment (`ticket.*.branch.push` matches `ticket.42.branch.push`, not `ticket.42.foo.branch.push`)
- `#` — zero or more segments (`ticket.42.#` matches everything about ticket 42)

## Agent-emittable names

These are the names you can pass to `emit_event(name, ...)`. Anything else is rejected.

| Name | When to emit | Topic published |
|------|--------------|-----------------|
| `progress.<slug>` | Hit a milestone within your ticket (`progress.brainstorm-end`, `progress.tests-green`) | `ticket.<id>.agent.progress.<slug>` |
| `decision.<slug>` | Made an architectural choice worth broadcasting (`decision.use-amqp-matcher`). The exact lifecycle names below are reserved. | `ticket.<id>.agent.decision.<slug>` |
| `decision.acknowledged` | You received a durable Executor answer and are beginning to apply it. Copy its `decision_id`, `action_id`, and request `expected_version` exactly. | `ticket.<id>.agent.decision.acknowledged` |
| `decision.resolved` | You finished the work governed by that answer. Use the same exact correlation after acknowledgement. | `ticket.<id>.agent.decision.resolved` |
| `blocked` | A specific integration point is non-stubbably blocked after `aiur_declare_blocker`; keep unrelated prep moving | `ticket.<id>.agent.blocked` |
| `unblocked` | You're no longer blocked (real or stubbed-then-fetch) | `ticket.<id>.agent.unblocked` |
| `attention.<slug>` | Need the Executor to answer something (opens ❗ in the agent list) | `ticket.<id>.agent.attention.<slug>` |
| `attention.resolved` | Closing a previously-opened attention; pass `payload: {slug: "<the-slug>"}` | `ticket.<id>.agent.attention.resolved` |
| `pause.request` | Ask the Executor to pause your turn at the next checkpoint | `ticket.<id>.agent.pause.request` |
| `custom.<slug>` | Anything else | `ticket.<id>.agent.custom.<slug>` |

> **Also allowed, but Executor-facing (not cross-ticket coordination):** the bare
> `progress` and `progress.checkin` names drive the Executor’s agent-list
> progress bar. They're allowed by `emit_event`, but their 1-of-10 estimation
> protocol and check-in cadence are documented in the agent pre-prompt's
> progress-bar guidance, not here.

## System-emitted topics (subscribe-only)

These you can subscribe to, but they're emitted by Aiur, not by you. Rows
marked **(auto)** are attached automatically when you start working on a ticket
(or via a blocker declaration) — you do **not** subscribe to them explicitly;
see `emit-and-subscribe.md` for the full automatic set.

| Topic | What it means |
|-------|---------------|
| `ticket.<id>.branch.push` | Someone pushed to an Aiur ticket branch (legacy or readable); the payload carries the actual ref. |
| `system.<branch>.branch.push` | Push to the repo's base branch (auto — you don't need to subscribe explicitly) |
| `ticket.<id>.pr.opened` | A PR was opened for this ticket |
| `ticket.<id>.pr.merged` | A PR for this ticket was merged |
| `ticket.<id>.issue.commented` | Someone left a comment on the GitHub issue (trusted-author filtered; auto for your own ticket) |
| `ticket.<id>.pr.review_comment` | Someone left a PR review comment (trusted-author filtered; auto for your own ticket) |
| `ticket.<id>.ci.passed` | Terminal CI pass for this ticket (auto for your own ticket) |
| `ticket.<id>.ci.failed` | Terminal CI failure for this ticket (auto for your own ticket) |

Note that the `agent.attention.*` family is **not** agent-exclusive: the
orchestrator also publishes `attention.state_divergence`,
`attention.waiting_for_human` (and `.resolved`), `attention.error-<cause>`,
`attention.error-lifetime_latch`, and `attention.unsupported_model` on
`ticket.<id>.agent.attention.*`. A subscriber to that pattern receives both
agent-authored and orchestrator-authored attentions.

## What you do NOT need to emit

- Don't emit `progress.commit` or `progress.push` — the GitHub firehose covers that.
- Don't emit `pr.opened` / `pr.merged` — same, from the firehose.
- Don't emit `issue.commented` — that's read from the firehose with trusted-author filtering applied.

Emit events for things only **you** know: architectural decisions, milestones inside your turn that aren't visible as git activity, and Executor-facing attentions.

The acknowledgement and resolution names are different from ordinary
architectural broadcasts: Aiur persists them in the Decision audit before
publishing. They are ticket-scoped, reject stale/wrong correlation, and are
idempotent when an agent turn is replayed.

## Per-turn quotas

Only the bare `progress` name is quota-capped: at most **two** bare `progress`
emits per turn — the 3rd returns `progress_cap_exceeded`, and the budget resets
at the next turn boundary. No other vocabulary name has a per-turn cap,
including `custom.<slug>` and `progress.<slug>`.

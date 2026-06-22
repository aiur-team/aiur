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
| `decision.<slug>` | Made an architectural choice worth broadcasting (`decision.use-amqp-matcher`) | `ticket.<id>.agent.decision.<slug>` |
| `blocked` | Your work is now blocked — typically called right after `aiur_declare_blocker` | `ticket.<id>.agent.blocked` |
| `unblocked` | You're no longer blocked (real or stubbed-then-fetch) | `ticket.<id>.agent.unblocked` |
| `attention.<slug>` | Need the operator to answer something (opens ❗ in the agent list) | `ticket.<id>.agent.attention.<slug>` |
| `attention.resolved` | Closing a previously-opened attention; pass `payload: {slug: "<the-slug>"}` | `ticket.<id>.agent.attention.resolved` |
| `pause.request` | Ask the operator to pause your turn at the next checkpoint | `ticket.<id>.agent.pause.request` |
| `custom.<slug>` | Anything else — capped at 5 per turn | `ticket.<id>.agent.custom.<slug>` |

> **Also allowed, but operator-facing (not cross-ticket coordination):** the bare
> `progress` and `progress.checkin` names drive the operator's agent-list
> progress bar. They're allowed by `emit_event`, but their 1-of-10 estimation
> protocol and check-in cadence are documented in the agent pre-prompt's
> progress-bar guidance, not here.

## System-emitted topics (subscribe-only)

These you can subscribe to, but they're emitted by Aiur, not by you.

| Topic | What it means |
|-------|---------------|
| `ticket.<id>.branch.push` | Someone pushed to `aiur/<id>` (via firehose or ls-remote) |
| `system.<branch>.branch.push` | Push to the repo's default branch (universal subscription — you don't need to subscribe explicitly) |
| `ticket.<id>.pr.opened` | A PR was opened for this ticket |
| `ticket.<id>.pr.merged` | A PR for this ticket was merged |
| `ticket.<id>.issue.commented` | Someone left a comment on the GitHub issue (CODEOWNERS-filtered) |
| `ticket.<id>.pr.review_comment` | Someone left a PR review comment (CODEOWNERS-filtered) |
| `ticket.<id>.issue.blocked_by.changed` | The dependency graph changed (someone called `aiur_declare_blocker`) |

## What you do NOT need to emit

- Don't emit `progress.commit` or `progress.push` — the GitHub firehose covers that.
- Don't emit `pr.opened` / `pr.merged` — same, from the firehose.
- Don't emit `issue.commented` — that's read from the firehose with CODEOWNERS filtering applied.

Emit events for things only **you** know: architectural decisions, milestones inside your turn that aren't visible as git activity, and operator-facing attentions.

## Custom event quota

`custom.*` events are capped at `events.custom_events_per_turn_max` (default 5) per turn. The 6th `custom.*` call in a turn returns `custom_event_quota_exceeded`. Use named categories (`progress`, `decision`, etc.) when one fits — they have no quota.

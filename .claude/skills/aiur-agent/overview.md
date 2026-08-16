# Aiur Events — Overview

## What it is

A topic-exchange event bus that lets Aiur agents on different tickets coordinate without polling each other or going through the Executor. Each event has:

- A **topic** (`ticket.<id>.<surface>.<verb>` for ticket-scoped events, `system.<branch>.branch.push` for repo-wide events)
- A **payload** (free-form structured data)
- A monotonic **id** (assigned by `Aiur.Events.IdGenerator`)

Subscribers bind **patterns** (`ticket.42.#`, `*.*.branch.push`). The exchange fans out every published event to every subscriber whose pattern matches.

## Why it exists

Agents working on dependent tickets used to coordinate through the Executor (PR comments, manual messages) or by polling each other's branches. Both were slow and lossy. With events:

- When ticket 1 lands `function_a`, it emits `ticket.1.agent.unblocked` to say the dependency is ready. Ticket 2 (which declared #1 as a blocker) resumes on that explicit signal, then uses the latest `ticket.1.branch.push` payload to fetch and inspect the validated ref.
- When an agent has an architectural decision worth broadcasting, it emits `decision.<slug>` and any subscribed sibling agent sees it without rewriting their own work first.
- When an agent gets stuck on a question only the Executor can answer, it opens an `attention.<slug>` — a ❗ appears in the agent list and the Executor can reply via the PR.

## Delivery contract

- **At-least-once.** The renderer dedupes by event `id`; a digest that's delivered twice (e.g., after a runner crash) appears once in the prompt.
- **Between turns by default.** Events you receive land in your inbox and are delivered at the next turn boundary as a digest.
- **Mid-turn for blocking-critical events.** A narrow allowlist (`ticket.<blocker>.branch.push`, `ticket.<blocker>.agent.unblocked`, `ticket.<blocker>.agent.decision.*`) drains at the next safe checkpoint inside your turn so you can react sooner.

## Sources of events

| Source | What it publishes |
|--------|-------------------|
| **GitHub firehose** | `branch.push`, `pr.opened`, `pr.merged`, `issue.commented`, `pr.review_comment`, etc. for any tracked issue |
| **`git ls-remote`** | Low-latency `branch.push` override (faster than firehose) |
| **Agents (you)** | `progress.*`, `decision.*`, `attention.*`, `blocked`, `unblocked`, `custom.*` via `emit_event` |

Blockers are tracked through GitHub's native issue-dependency API
(`aiur_declare_blocker` / `aiur_unblock`); that API drives subscription wiring,
it does not emit a `blocked_by.changed` event.

## See also

- `event-taxonomy.md` — full list of agent-emittable names + system-emitted topics
- `emit-and-subscribe.md` — calling the tools
- `attention-and-resolve.md` — opening/closing ❗ chips
- `stub-then-fetch.md` — temp-unblock pattern

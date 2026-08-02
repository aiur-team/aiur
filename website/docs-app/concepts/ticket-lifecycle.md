# How a ticket flows

`issue → workspace → agent turn → draft PR → CI wait → review → merge`

## 1. Issue

A labeled `agent:todo` ticket enters the queue. The orchestrator orders candidates and dispatches those that pass the slot and blocker gates.

## 2. Workspace

Dispatch provisions an isolated clone or workspace for the run. Each workspace writes a human-readable `logs/agent.md` transcript and a structured `logs/agent.ndjson` event stream.

## 3. Agent turn

The agent works on branch `aiur/<issue-number>`, running one or more turns while the ticket stays active, up to the configured `max_turns`. It keeps a single `## Agent Workpad` issue comment current.

## 4. Draft PR

The agent opens a draft pull request whose description starts `Closes #<issue>`, runs the scoped local gate, and self-reviews the pushed diff.

## 5. CI wait

When no code work remains, the agent moves the ticket to `agent:ci-wait` and yields its turn and dispatch slot. The central GitHub CI poller publishes the terminal pass or failure event; a configurable fallback re-wakes the agent for one recovery check if no event arrives. A pass lets the agent mark the PR ready and move to `agent:human-review`; a failure moves it to `agent:rework` with failed-check context.

## 6. Review

Code-owner and reviewer comments are classified. Authoritative feedback moves the ticket to `agent:rework` and re-dispatches the agent on the same workspace to address it. The agent never self-merges; human review is required.

## 7. Merge

When the PR merges, the ticket terminalizes to `agent:done` and the issue closes.

## 8. The Agent Workpad convention

The Agent Workpad is a single pinned issue comment beginning `## Agent Workpad` that the agent keeps current across turns. It is filtered from event polling, so the agent's own workpad edits never wake agents or spam digests.

# How a ticket flows

`issue → workspace → agent turn → draft PR → CI wait → review → merge`

## 1. Issue

A labeled `agent:todo` ticket enters the queue. The orchestrator orders candidates and dispatches those that pass the slot and blocker gates.

Tickets without an `agent:*` label are deliberately invisible to dispatch — that is how an operator parks work ("decide before this is built"). Nothing auto-assigns a state to such a ticket. The two intentional auto-labelling paths — a CI failure moves a *worked* ticket to `agent:rework`, and an authoritative review comment does the same — only ever flip tickets that already carry an `agent:*` state. An unlabelled ticket stays unlabelled until a human or an explicitly authorized command changes it.

An operator can make the hold explicit with the `agent:parked` marker label: dispatch ignores the ticket and comment-driven rework is refused even when an active state label is present. `agent:parked` survives state swaps and label sweeps, so it is the positive, self-documenting form of the same intent an unlabelled ticket expresses by absence.

## 2. Workspace

Dispatch provisions an isolated clone or workspace for the run. Each workspace writes a human-readable `logs/agent.md` transcript and a structured `logs/agent.ndjson` event stream.

## 3. Agent turn

The agent works on a generated ticket branch, running one or more turns while the ticket stays active, up to the configured `max_turns`. It keeps a single `## Agent Workpad` issue comment current.

## 4. Draft PR

The agent opens a draft pull request whose description starts `Closes #<issue>`, runs the scoped local gate, and self-reviews the pushed diff.

## 5. CI wait

When no code work remains, the agent moves the ticket to `agent:ci-wait` and yields its turn and dispatch slot. A CI pass lets the agent mark the PR ready and move to `agent:human-review`; a failure moves it to `agent:rework` with failed-check context. If no CI result arrives, a configurable fallback re-wakes the agent for one recovery check.

## 6. Review

Code-owner and reviewer comments are classified. Authoritative feedback moves the ticket to `agent:rework` and re-dispatches the agent on the same workspace to address it. The agent never self-merges; human review is required.

## 7. Merge

When the PR merges, the ticket terminalizes to `agent:done` and the issue closes.

## 8. The Agent Workpad convention

The Agent Workpad is a single pinned issue comment beginning `## Agent Workpad` that the agent keeps current across turns.

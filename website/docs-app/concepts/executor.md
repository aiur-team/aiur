# Executor

The Executor is a **role**, not a program. It is filled either by the human or by an agent the human designates to drive. The role does three things:

1. Runs Aiur: launches the daemon, sets the concurrency cap, pauses and resumes.
2. Assigns tickets to agents: queues work and applies the labels that make a ticket dispatchable.
3. Tracks how tickets are progressing, and unblocks them when they stall.

Everything the role needs is available on all three surfaces. The [Dashboard](/guide/executor-control-center) is the browser view, the [TUI](/guide/tui) is the terminal board, and the [CLI](/reference/cli) is the shape an agent Executor drives. They read and write the same daemon state, so the choice of surface is a preference, not a capability boundary.

## Who fills the role

| Executor | How it drives | Typical use |
| --- | --- | --- |
| Human | TUI board and chat panes, or the dashboard. | Small fleets, close supervision, hands on the merge decision. |
| Designated agent | `aiur --bg` plus the CLI, following the `aiur-run` skill. | Long or unattended runs, large fleets, continuous triage. |

An agent Executor still cannot merge on the human's behalf. Aiur requires human review before a PR lands, and the agent working a ticket never self-merges.

## Use a second agent even when you drive

Running Aiur yourself is not a reason to read logs yourself. An agent parses a run far faster than a person can, so pair your own driving with an agent whose only job is to analyse progress: catch snags, surface blockers, and find the background issues that never make it into an alert.

This is not a nicety. The recurring `aiur-meta` check exists because one manual audit found four defects that `aiur status`, `aiur alerts`, and in three cases the HTTP API did not reveal. A surface reporting a confident wrong number is more dangerous than a visible failure, and a second agent is what catches it.

Practically:

- Arm the hourly [meta-check](/concepts/operating-aiur#hourly-meta-check) at the start of a run, before dispatching.
- Have the analysis agent read `aiur watch --full`, `aiur alerts --needs-attention`, and `aiur findings --unfiled`, not one metric.
- Let it name the current biggest wall-clock bottleneck each pass. A completed checklist is not a finding.

## What the Executor decides

Agents escalate rather than guess. Two durable channels reach the Executor:

- **[Commands](/concepts/commands)**, the decision inbox. An agent records a decision request and stops; the Executor answers it, or defers it to a supervising Executor agent.
- **Asks**, created with `aiur ask`. An open blocking ask is printed by plain `aiur status`, so a durable request stays in the normal operating view.

Both are append-only records. A revision adds a new action rather than rewriting the original, so decision history stays auditable.

## Handoff

An Executor that runs out of context hands off. The durable narrative is the per-boot retrospective at `~/.aiur/repo/<owner>/<repo>/meta/retros/<boot-id>.md`, and deferred findings go into `meta/findings.ndjson` through `aiur findings --record`. See [State nodes](/reference/state-nodes) for the full layout. Git history and a stale dashboard tab are not current state.

# What Aiur is

## What it is

Aiur turns project work into isolated, autonomous implementation runs so teams manage work instead of supervising individual coding sessions. It watches a tracker for labeled work, starts an isolated run for each selected ticket, and produces proof of work such as CI status, PR review feedback, complexity analysis, and a walkthrough before landing an accepted PR.

## Tracker-driven

Trackers are pluggable adapters configured with `tracker.kind`. Aiur can use:

- A Linear board.
- GitHub issues.
- The in-memory tracker.

On trackers that support labels, Aiur runs a label-based state machine.

## The label lifecycle

With the default `agent` label prefix, a GitHub ticket follows this lifecycle:

1. `agent:todo`: queued work.
2. `agent:in-progress`: an isolated run is active.
3. `agent:ci-wait`: implementation is complete and the central daemon is awaiting terminal PR CI without holding an agent turn or dispatch slot.
4. `agent:human-review`: CI passed and the PR is ready for human review.
5. `agent:rework`: CI or reviewer feedback requires another run, looping back through review.
6. `agent:merging`: the accepted PR is being merged.
7. `agent:done`: the work is complete.

The terminal error and cancellation states are `agent:error` and `agent:cancelled` (also spelled `agent:canceled`). `agent:watch` labels a PR for monitoring; it is deliberately not a dispatch state. Agents keep the Agent Workpad current, move tickets to human review when the PR is ready, and never self-merge.

## Complexity routing

Each ticket carries a `complexity:1`–`complexity:5` label. That label routes the model, agent, and skill depth, while the run resolves its backend, model, and effort from the issue labels.

## Backends

Implementation backends plug in behind Aiur's app-server protocol. A `model:<backend>` label routes a ticket to a backend, and `model:remote` enables remote control.

- `codex`
- `claude` (headless)
- `claude-repl` (the persistent interactive REPL that backs remote control)
- `kimi`, `openrouter` (generic OpenAI-compatible instances, configurable by default)
- `deepseek` (generic OpenAI-compatible instance; ships disabled and needs `agent.backend_configs.deepseek.enabled: true` to dispatch)

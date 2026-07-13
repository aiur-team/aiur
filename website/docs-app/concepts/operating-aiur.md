# Operating Aiur

## The TUI board

The terminal agent-list board shows running, paused, and idle ticket rows with runtime, turn count, backend, pinned model, work state, and pause reason.

## The dashboard

The Phoenix web dashboard supports Basic Auth and can bind to a configured host and port for private access. While a run is active, it opens that run's `logs/agent.md` in a live-updating modal.

## Alerts

Alerts are defined in the checked-in `.aiur/alerts` file. Each entry is keyed by an event-topic glob pattern and carries a `message` plus an optional `sound` list. Agents raise milestone alerts with `emit_alert`.

## Pause / resume

Executors can pause and resume agents. A paused agent keeps its slot, so polling cannot auto-claim over it. The concurrency cap can change at runtime with the arrow keys or `aiur set max-agents N`; the space key starts a queued ticket.

## Remote control

Remote control is opt-in per agent through the `model:remote` label or the `r` key. It rides the persistent `claude-repl` session and is local-only in v1. The opencode chat panes let an Executor type into the live session while the Codex/Claude runtime and transcript remain the source of truth.

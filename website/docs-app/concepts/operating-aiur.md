# Operating Aiur

## The TUI board

The terminal agent-list board shows running, paused, and idle ticket rows with runtime, turn count, backend, pinned model, work state, and pause reason.

## The dashboard

The [Executor Control Center](/guide/executor-control-center) combines the live fleet, durable decision inbox and history, recent outcomes, and a link to offline telemetry analytics. It is read-only by default. Browser writes require an explicit configuration gate, and writable or non-loopback deployments require Basic Auth.

## Alerts

Alerts are defined in the checked-in `.aiur/alerts` file. Each entry is keyed by an event-topic glob pattern and carries a `message` plus an optional `sound` list. Agents raise milestone alerts with `emit_alert`.

## Pause / resume

Executors can pause and resume agents. A paused agent keeps its slot, so polling cannot auto-claim over it. The concurrency cap can change at runtime with the arrow keys or `aiur set max-agents N`; the space key starts a queued ticket.

## Remote control

Remote control is opt-in per agent through the `model:remote` label or the `r` key. It rides the persistent `claude-repl` session and is local-only in v1. The opencode chat panes let an Executor type into the live session while the Codex/Claude runtime and transcript remain the source of truth.

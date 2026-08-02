# Operating Aiur

## The TUI board

The terminal agent-list board shows running, paused, and idle ticket rows with runtime, turn count, backend, pinned model, work state, and pause reason.

## The dashboard

The [Executor Control Center](/guide/executor-control-center) combines the live fleet, durable decision inbox and history, recent outcomes, provider meters, Build Orders, and analytics. Dashboard writes are enabled by default, but writable or non-loopback deployments require Basic Auth.

## Alerts

Alerts are defined in the checked-in `.aiur/alerts` file. Each entry is keyed by an event-topic glob pattern and carries a `message` plus an optional `sound` list. Agents raise milestone alerts with `emit_alert`.

## Usage and account meters

Aiur retains token usage by ticket and resolves API-equivalent cost only when it has the provider, model, pricing date, and required pricing dimensions. The built-in price table currently covers the registered Codex and Claude provider families. Dashboard usage views keep unknown or partial pricing explicit instead of converting it to a zero-dollar total.

The dashboard and `aiur usage` show account-meter observations with their age. Codex reports percentage usage for its renewing windows. Claude can report a standing and reset time without a percentage, so Aiur shows that state rather than drawing an empty percentage bar. No prepaid provider is registered in the current build, so the UI does not claim a dollar balance, concurrency cap, or remaining-quota header for DeepSeek, Kimi, or OpenRouter.

## Pause / resume

Executors can pause and resume agents. Space toggles the selected ticket pause. Bare `aiur pause` and `aiur resume` operate a separate global switch that stops all provisioning and persists across restart. The concurrency cap can change at runtime with the arrow keys or `aiur set max-agents N`.

## Remote control

Remote control is opt-in per agent through the `model:remote` label or the `r` key. It rides the persistent `claude-repl` session and is local-only in v1. The opencode chat panes let an Executor type into the live session while the Codex/Claude runtime and transcript remain the source of truth.

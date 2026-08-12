# Operating Aiur

## The TUI board

The terminal agent-list board shows running, paused, and idle ticket rows with runtime, turn count, backend, pinned model, work state, and pause reason.

## The dashboard

The [Dashboard](/guide/executor-control-center) combines the live fleet, durable decision inbox and history, recent outcomes, provider meters, Build Orders, and analytics. Dashboard writes are enabled by default, but writable or non-loopback deployments require Basic Auth.

## Hourly meta-check

`aiur-run` arms a recurring one-hour `aiur-meta` check at the start of a run, **before dispatching**. It is not a status poll: the check captures and looks at Units, Commands, Build Orders, and Analytics; times the interactive CLI and treats empty or timed-out responses as findings; compares host load with the configured gate; audits the PR backlog; then names one bottleneck and records it durably.

The timer matters because an Executor deep in a merge queue should not have to remember an hourly audit. The first manual parity-run check found four defects that `aiur status`, `aiur alerts`, and, for three of them, the HTTP API did not reveal. A surface with a confident wrong number is more dangerous than a visible failure, so the check records what an operator can actually see rather than inferring health from one backend metric.

## Alerts

Alerts are defined in the checked-in `.aiur/alerts` file. Each entry is keyed by an event-topic glob pattern and carries a `message` plus an optional `sound` list. Agents raise milestone alerts with `emit_alert`.

## Usage and account meters

Aiur retains token usage by ticket and resolves API-equivalent cost only when it has the provider, model, pricing date, and required pricing dimensions. The built-in price table covers the registered provider families. Dashboard usage views keep unknown or partial pricing explicit instead of converting it to a zero-dollar total.

The dashboard shows provider meters with the age of each observation; `aiur usage` prints limit headroom observed from live agent sessions. Codex and Claude show percentage use of renewing allotment windows. DeepSeek and OpenRouter expose prepaid dollar or credit balances instead of remaining-quota headers. DeepSeek also has a separately displayed local concurrency cap. A DeepSeek percentage can appear only when Aiur has a durable prepaid-balance baseline, and means spend against that baseline, not a provider quota. Kimi is session-observation only and has no account-balance probe.

## Pause / resume

Executors can pause and resume agents. Space toggles the selected ticket pause. Bare `aiur pause` and `aiur resume` operate a separate global switch that stops all provisioning and holds the daemon. On a writable dashboard, the sidebar pause button controls that same durable switch; its neighboring navigation button only collapses or expands the sidebar. The switch survives a restart with recorded provenance, and a restart that cannot read the persisted state fails closed and starts paused rather than releasing a fleet an operator deliberately parked. Launch with `--pause` to cold-start paused. The concurrency cap can change at runtime with the arrow keys or `aiur set max-agents N`; `aiur status` prints which capacity bound is actually limiting the fleet.

## Remote control

Remote control is opt-in per agent through the `model:remote` label or the `r` key. It rides the persistent `claude-repl` session and is local-only in v1. The opencode chat panes let an Executor type into the live session while the Codex/Claude runtime and transcript remain the source of truth.

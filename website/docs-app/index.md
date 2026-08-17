# Overview

Coordinate coding agents via events.

<VPButton theme="brand" text="Quick start" href="/guide/quick-start" />

## What Aiur is

Aiur turns tracker work into isolated implementation runs.

| Stage | Aiur does |
| --- | --- |
| Select | Watches labelled tracker tickets. |
| Run | Starts one isolated agent run per dispatched ticket. |
| Prove | Surfaces CI, review feedback, complexity, and walkthrough evidence. |
| Finish | Returns an accepted PR for human-controlled landing. |

## Tracker-driven

Choose a tracker with `tracker.kind`.

| `tracker.kind` | Source |
| --- | --- |
| `linear` | Linear board. |
| `github` | GitHub issues. |
| `memory` | In-memory tracker. |

On trackers that support labels, Aiur runs a label-based state machine.

## The label lifecycle

| Label | Meaning |
| --- | --- |
| `agent:todo` | Queued work. |
| `agent:in-progress` | Isolated run active. |
| `agent:ci-wait` | Code complete; waiting for terminal CI. |
| `agent:human-review` | CI passed; PR ready for human review. |
| `agent:rework` | CI or review requires another run. |
| `agent:merging` | Accepted PR entering merge. |
| `agent:done` | Work complete. |

The terminal error and cancellation states are `agent:error` and `agent:cancelled` (also spelled `agent:canceled`). `agent:watch` labels a PR for monitoring; it is deliberately not a dispatch state. Agents keep the Agent Workpad current, move tickets to human review when the PR is ready, and never self-merge.

## Complexity routing

Each ticket carries a `complexity:1`–`complexity:5` label. That label routes the model, agent, and skill depth, while the run resolves its backend, model, and effort from the issue labels.

## Backends

Choose an implementation backend with a `model:<backend>` label, and add `model:remote` to enable remote control.

| Backend | Notes |
| --- | --- |
| `codex` | Default Codex backend. |
| `claude` | Headless Claude backend. |
| `claude-repl` | Persistent interactive backend for remote control. |
| `kimi`, `openrouter` | Configurable OpenAI-compatible instances. |
| `deepseek` | OpenAI-compatible; requires explicit `enabled: true`. |

Kimi, DeepSeek, and OpenRouter have separate credentials and defaults. Route by a `model:<backend>` label, or name the backend in `agent.routing`; a bare backend label uses that backend's default model. For example:

```yaml
agent:
  routing:
    "complexity:3": kimi
  backend_configs:
    deepseek:
      enabled: true
```

The registry reads `MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`, and `OPENROUTER_API_KEY`; OpenRouter's balance meter additionally uses `OPENROUTER_MANAGEMENT_KEY`. DeepSeek is deliberately not dispatchable until the explicit `enabled: true` opt-in is present.

## Browse the docs

| Goal | Page |
| --- | --- |
| Install and start | [Quick start](/guide/quick-start) |
| Stream Deck controls | [Operate the Stream Deck](/guide/stream-deck) |
| Configure a workflow | [Configuration](/reference/configuration) |
| Run and control Aiur | [CLI](/reference/cli) |
| Understand the driver | [Executor](/concepts/executor) |
| Read fleet work | [Units](/concepts/units) |
| Resolve agent issues | [Commands](/concepts/commands) |
| Follow large features | [Build Orders](/concepts/build-orders) |
| Follow ticket state | [How a ticket flows](/concepts/ticket-lifecycle) |
| Choose workflows | [Skills](/skills) |

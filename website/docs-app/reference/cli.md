# CLI and control commands

`aiur` starts and controls one instance-keyed run. The repository’s `scripts/aiurdev` shim exposes the same runtime command surface against a local development release.

## Start a run

| Command | Purpose |
| --- | --- |
| `aiur` or `aiur run` | Start the interactive foreground run. |
| `aiur --bg` | Start a detached headless run with the web dashboard enabled. |
| `aiur --bg --no-dashboard` | Start a lean detached run without the dashboard listener. |
| `aiur --no-dashboard` | Start the foreground terminal UI without the dashboard listener. |
| `aiur --max-agents N` | Override the configured concurrency cap for this launch. |
| `aiur --todo 142 143` | Queue the listed ticket IDs. |
| `aiur --todo 142 143 --only` | Queue those IDs and dequeue other pending tickets. |
| `aiur --host 127.0.0.1 --port 4000` | Override the dashboard bind for this launch. |
| `aiur --debug` | Enable durable debug logging and chat-pane recording. |

Foreground mode provides the terminal board and live chat panes. Background mode omits that terminal UI but continues serving the web dashboard. Detachment and dashboard availability are independent; add `--no-dashboard` in either mode to suppress the HTTP listener. Because Claude Remote Control lifecycle hooks post to that listener, Aiur rejects `--no-dashboard` when `agent.remote_control` is enabled or an `agent.routing` value uses `+remote`, and refuses later `model:remote` or live Remote Control activation while no listener is bound. A background launch prints the confirmed bound URL or an explicit listener-unavailable warning. Non-loopback dashboard binds still require `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`.

## Inspect a run

| Command | Purpose |
| --- | --- |
| `aiur status` | Report whether the instance and control plane are running. |
| `aiur agents` | Print one line per agent with state, runtime, and activity. |
| `aiur watch` | Render a one-shot fleet board. |
| `aiur watch --interval 5` | Refresh the board every five seconds. |
| `aiur alerts --needs-attention` | Show unresolved alerts that need Executor attention. |

## Control a run

| Command | Purpose |
| --- | --- |
| `aiur set max-agents N` | Change the live concurrency cap without editing config. |
| `aiur pause 142 143` | Cooperatively pause specific tickets. |
| `aiur pause --all` | Pause all active tickets. |
| `aiur resume 142 143` | Resume specific paused tickets. |
| `aiur resume --all` | Resume all paused tickets. |
| `aiur message 142 "Check the latest review"` | Deliver an Executor message through the agent’s native queue. |
| `aiur stop` | Stop the BEAM and its tmux lifetime session. |

A pause takes effect at a safe turn boundary. It preserves the ticket’s lifecycle state; resuming removes only the pause override.

## Initialize configuration

| Command | Purpose |
| --- | --- |
| `aiur init` | Scaffold `.aiur/config`, `.aiur/hooks`, and `.aiur/prompt.md`. |
| `aiur init --force` | Recreate configuration while preserving sibling scaffold files. |

The CLI discovers `./.aiur/config`, then legacy `./.aiurconfig`, then the corresponding files under the user’s home directory. See [Configuration reference](/reference/configuration).

# CLI and control commands

`aiur` is the installed CLI. `scripts/aiurdev` rebuilds a local development release when needed, then executes the same launcher engine. Apart from `aiurdev build` and the development smoke-harness flags below, they are one CLI surface, not two products.

Use the command from the repository that owns the run. An instance is keyed to that project, so control commands address that repository's daemon.

## Start, initialize, and queue

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur` <!-- cli-command: run --> | Starts a foreground interactive run. The launcher supplies a loopback host, interactive UI, and required guardrail acknowledgement when absent. | `aiur` |
| `aiur run` <!-- cli-command: run --> | Explicit foreground launch form. `--bg` makes it headless; `--interactive` restores terminal panes in a background session. | `aiur run --bg` |
| `aiur init` <!-- cli-command: init --> | Interactive setup detects the tracker and toolchain, writes `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`, `.aiur/alerts`, and prewarm support when selected, then creates the repository state-node tree and warms the base build. | `aiur init` |
| `aiur init --force` <!-- cli-flag: --force --> | Recreates generated configuration. Re-running without it preserves existing scaffold files. | `aiur init --force` |
| `aiur --todo 142 143` <!-- cli-flag: --todo --> | Requires a running daemon and one or more numeric IDs, with commas also accepted. A stopped daemon exits nonzero. | `aiur --todo 142,143` |
| `aiur --todo 142 --only` <!-- cli-flag: --only --> | Queues the named IDs and asks GitHub to remove `agent:todo` from other pending tickets. It is GitHub-only, is bounded to 50 cleanup targets, and stops after three consecutive rate-limit failures. Cleanup is skipped if a requested ID fails, so the operation does not silently dequeue work after a bad request. | `aiur --todo 142 --only` |
| `aiur --bg` <!-- cli-flag: --bg --> | Starts detached headless execution. It has no agent-list or chat panes; use the dashboard or control commands. | `aiur --bg` |
| `aiur --debug` <!-- cli-flag: --debug --> | Enables debug logs and durable chat-pane recording for this run. | `aiur --debug` |
| `aiur --pause` <!-- cli-flag: --pause --> | Cold-starts with the global provisioning switch paused. | `aiur --pause` |
| `aiur --max-agents 6` <!-- cli-flag: --max-agents --> | Launch-only session cap. It wins over `agent.max_concurrent_agents`; Aiur warns when it exceeds that setting. `status` identifies the active binding. | `aiur --max-agents 6` |
| `aiur --interactive` <!-- cli-flag: --interactive --> | Requests the terminal UI, including from a background launch. | `aiur --bg --interactive` |
| `aiur --headless` <!-- cli-flag: --headless --> | Requests no terminal UI. Background launch injects it unless `--interactive` is present. | `aiur run --headless` |
| `aiur --no-dashboard` <!-- cli-flag: --no-dashboard --> | Suppresses the dashboard listener in foreground or background mode. It is rejected for Remote Control because its lifecycle hooks need the listener. | `aiur --bg --no-dashboard` |
| `aiur --host 127.0.0.1` <!-- cli-flag: --host --> | Overrides the dashboard bind host. A non-loopback host requires dashboard credentials. | `aiur --host 127.0.0.1` |
| `aiur --port 4000` <!-- cli-flag: --port --> | Overrides the HTTP port. `0` lets the OS choose a free port. | `aiur --port 4000` |
| `aiur --logs-root /var/log/aiur` <!-- cli-flag: --logs-root --> | Overrides the daemon log root for this launch. | `aiur --logs-root /var/log/aiur` |
| `aiur --i-understand-that-this-will-be-running-without-the-usual-guardrails` <!-- cli-flag: --i-understand-that-this-will-be-running-without-the-usual-guardrails --> | Required by the release parser; the launcher inserts it for normal run commands. | `aiur run --i-understand-that-this-will-be-running-without-the-usual-guardrails` |
| `aiur --version` <!-- cli-flag: --version --> | Prints the release version without contacting or claiming a running daemon. | `aiur --version` |

Foreground mode has the terminal board and chat panes. `--bg` is headless but still starts the dashboard unless `--no-dashboard` is passed. The default host is loopback, or an authenticated Tailscale address when one is safely available.

## Inspect and operate a running daemon

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur help` <!-- cli-command: help --> | Prints the current launcher usage. | `aiur help` |
| `aiur status` <!-- cli-command: status --> | Shows daemon and capacity status, including `AGENTS occupied/max (binding: ...)`. The binding is `config max_concurrent_agents`, `AIMD envelope`, `paused reservations`, `ticket supply`, `session max_concurrent_agents`, or `none`. `ticket supply` means no queued ticket is available, not that the configured cap is zero. | `aiur status` |
| `aiur usage` <!-- cli-command: usage --> | Prints the current provider-meter observations and their known headroom. | `aiur usage` |
| `aiur agents` <!-- cli-command: agents --> | Prints each active agent's state and current activity. | `aiur agents` |
| `aiur watch` <!-- cli-command: watch --> | Shows changed fleet rows by default. | `aiur watch` |
| `aiur watch --full` <!-- cli-flag: --full --> | Prints all fleet rows. | `aiur watch --full` |
| `aiur watch --changes` <!-- cli-flag: --changes --> | Makes the changed-rows default explicit. | `aiur watch --changes` |
| `aiur watch --once` <!-- cli-flag: --once --> | Requests the one-shot form. | `aiur watch --once` |
| `aiur watch --interval 5` <!-- cli-flag: --interval --> | Re-renders until interrupted. The interval must be a positive number of seconds. | `aiur watch --interval 5` |
| `aiur alerts` <!-- cli-command: alerts --> | Shows the structured alert feed. | `aiur alerts` |
| `aiur alerts --needs-attention` <!-- cli-flag: --needs-attention --> | Filters to unresolved alerts requiring Executor action. | `aiur alerts --needs-attention` |
| `aiur set max-agents 6` <!-- cli-command: set --> | Changes the live session cap without editing config. It takes effect immediately and does not rewrite the next launch's config. | `aiur set max-agents 6` |
| `aiur pause` <!-- cli-command: pause --> | Turns on the global pause switch. It stops new provisioning and cooperatively holds the fleet. The switch is persisted with its source and survives restart; a failed persisted-state read starts paused. | `aiur pause` |
| `aiur resume` <!-- cli-command: resume --> | Turns off that global switch. | `aiur resume` |
| `aiur pause 142 143` | Requests a safe-boundary pause for named tickets. | `aiur pause 142,143` |
| `aiur pause --all` <!-- cli-flag: --all --> | Requests a pause for every active ticket. | `aiur pause --all` |
| `aiur resume 142` | Resumes a paused ticket, or starts an idle eligible ticket. | `aiur resume 142` |
| `aiur resume --all` | Resumes every individually paused ticket. | `aiur resume --all` |
| `aiur reset-budget 142` <!-- cli-command: reset-budget --> | Clears a named ticket's dispatch-budget latch. It does not accept `--all`; `resume` cannot clear this latch. | `aiur reset-budget 142` |
| `aiur message 142 "Check review"` <!-- cli-command: message --> | Delivers Executor text through the native agent queue. Aiur may interrupt at a safe point, queue it for the next turn, auto-resume a paused entry, or reactivate a deactivated entry. Text must be nonblank and at most 8,000 characters. | `aiur message 142 "Check the latest review"` |
| `aiur stop` <!-- cli-command: stop --> | Stops the BEAM and its tmux lifetime session. A stopped daemon makes `stop` and `--todo` exit nonzero. | `aiur stop` |
| `aiur cleanup-stale` <!-- cli-command: cleanup-stale --> | Lists and reaps stale manual-smoke processes and sockets. | `aiur cleanup-stale` |
| `aiur cleanup-stale --dry-run` <!-- cli-flag: --dry-run --> | Reports stale leftovers without reaping them. | `aiur cleanup-stale --dry-run` |

## Decisions, Executor events, and findings

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur commands` <!-- cli-command: commands --> | Lists durable Executor decisions. An optional decision ID selects one record. | `aiur commands` |
| `aiur commands --filter open` <!-- cli-flag: --filter --> | Accepts `all`, `open`, `blocking`, or `resolved`. `--ticket` and `--search` require `--filter all`. | `aiur commands --filter open` |
| `aiur commands --blocking` <!-- cli-flag: --blocking --> | Limits the decision list to blocking records. | `aiur commands --blocking` |
| `aiur commands --ticket 142` <!-- cli-flag: --ticket --> | Narrows an `all` decision query to a ticket. | `aiur commands --filter all --ticket 142` |
| `aiur commands --search timeout` <!-- cli-flag: --search --> | Searches an `all` decision query. | `aiur commands --filter all --search timeout` |
| `aiur commands --cursor TOKEN` <!-- cli-flag: --cursor --> | Continues a paginated decision query. | `aiur commands --cursor TOKEN` |
| `aiur commands --limit 20` <!-- cli-flag: --limit --> | Sets a positive result limit. | `aiur commands --limit 20` |
| `aiur commands --json` <!-- cli-flag: --json --> | Emits machine-readable decision rows. | `aiur commands --json` |
| `aiur executor-listen` <!-- cli-command: executor-listen --> | Persists the requested subscription, then streams all persisted-pattern events after the saved cursor before live events as JSON lines. It intentionally does not use the ten-second one-shot RPC timeout. | `aiur executor-listen` |
| `aiur executor-listen --topic 'executor.#'` <!-- cli-flag: --topic --> | Adds that validated AMQP topic pattern before listening; the default is `executor.#`. Empty segments and malformed patterns are rejected. | `aiur executor-listen --topic 'executor.#'` |
| `aiur executor-emit executor.note --payload '{"text":"ready"}'` <!-- cli-command: executor-emit --> <!-- cli-flag: --payload --> | Publishes JSON on a nonempty `executor.` topic. Empty segments and other namespaces are rejected. | `aiur executor-emit executor.note --payload '{"text":"ready"}'` |
| `aiur executor-subscribe 'executor.#'` <!-- cli-command: executor-subscribe --> | Adds a persistent Executor event binding. | `aiur executor-subscribe 'executor.#'` |
| `aiur executor-unsubscribe 'executor.#'` <!-- cli-command: executor-unsubscribe --> | Removes that exact persistent binding. | `aiur executor-unsubscribe 'executor.#'` |
| `aiur executor-subscriptions` <!-- cli-command: executor-subscriptions --> | Lists persistent Executor event bindings. | `aiur executor-subscriptions` |
| `aiur findings` <!-- cli-command: findings --> | Reads the host-local findings ledger. | `aiur findings` |
| `aiur findings --unfiled` <!-- cli-flag: --unfiled --> | Filters ledger entries that have no filed ticket. | `aiur findings --unfiled` |
| `aiur findings --slugs` <!-- cli-flag: --slugs --> | Emits only finding slugs. | `aiur findings --slugs` |
| `aiur findings --scope repo` <!-- cli-flag: --scope --> | Filters to `aiur` or `repo` scope. | `aiur findings --scope repo` |
| `aiur findings --record JSON --repo owner/repo` <!-- cli-flag: --record --> <!-- cli-flag: --repo --> | Appends one validated finding to the named repository ledger. Both options are required together. | `aiur findings --record '{"slug":"example"}' --repo aiur-team/aiur` |
| `aiur findings --digest` <!-- cli-flag: --digest --> | Generates the Markdown projection, optionally scoped. | `aiur findings --digest --scope repo` |

Normal control commands use a bounded RPC. After ten seconds the launcher terminates its helper and descendants, exits 124, and reports the timeout. A crash marker distinguishes a known crashed daemon from a stopped one; run `aiur stop` to reap possible orphaned agents before restarting.

## Development-only `aiurdev` commands

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `scripts/aiurdev build` <!-- cli-dev-command: build --> | Rebuilds the local release before the next run. The installed `aiur` does not have this command. | `scripts/aiurdev build` |
| `scripts/aiurdev build --deps` <!-- cli-flag: --deps --> | Rebuilds dependencies as part of the development build. | `scripts/aiurdev build --deps` |
| `scripts/aiurdev --test` <!-- cli-flag: --test --> | Resets the single sandbox ticket, first stopping the keyed live daemon, then starts the foreground smoke harness. It is blocked from agent workspaces. | `scripts/aiurdev --test --force` |
| `scripts/aiurdev --test3` <!-- cli-flag: --test3 --> | Resets the three-ticket blocker-chain harness, stops the keyed live daemon first, and permits the remote scenario. It is blocked from agent workspaces. | `scripts/aiurdev --test3` |
| `scripts/aiurdev --clear` <!-- cli-flag: --clear --> | Requires debug mode and deletes every entry under `~/.aiur/logs/` before the smoke run, not merely debug logs. | `scripts/aiurdev --debug --clear` |
| `scripts/aiurdev --allow-remote` <!-- cli-flag: --allow-remote --> | Permits the remote test scenario. | `scripts/aiurdev --test3 --allow-remote` |

`aiurdev` refuses every invocation from an existing tmux session because Aiur starts its own tmux socket. It pins the opencode binary selected by the release and preserves a complete existing release for control commands, so a control command does not rebuild a daemon it is about to contact.

`aiur` accepts a path to a workflow configuration as the final run argument. The `findings` markers above are the current implemented surface, not a planned interface.

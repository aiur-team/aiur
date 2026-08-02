# CLI and control commands

`aiur` is the installed command. `scripts/aiurdev` is its development wrapper: both dispatch to the same launcher engine and have the same command surface. `aiurdev` selects the local release and rebuilds it when necessary. Its only product-surface exception is `aiurdev build [--deps]`, which force-rebuilds the local release and does not exist in an installed `aiur`.

Run commands from the repository root, or from a subdirectory beneath a repository-local `.aiur/config`. A run keyed only by a home-level config is keyed by its launch directory, so control commands must be run from that same directory.

## Start a run

<!-- cli-command: help -->
<!-- cli-command: -h -->
<!-- cli-command: -help -->
<!-- cli-command: --h -->
<!-- cli-command: --help -->
<!-- cli-command: run -->
<!-- cli-command: --bg -->
<!-- cli-command: --version -->
<!-- cli-command: init -->
<!-- cli-command: --todo -->

`aiur`, `aiur run`, and `aiur <config-path>` start a foreground run. The launcher loads `./.env` before starting, without replacing already-exported variables.

| Command or flag | Default and effect | Runnable example |
| --- | --- | --- |
| `aiur` | Foreground, interactive terminal board and dashboard. | `aiur` |
| `aiur run` | Explicit foreground spelling of the bare command. | `aiur run` |
| `aiur <path>` | Uses that `.aiur/config` or legacy `.aiurconfig` path. | `aiur .aiur/config` |
| `--bg` | Starts a detached, headless run. It has no terminal board or chat panes, but keeps the dashboard unless suppressed. Repeating a live background start is idempotent. | `aiur --bg` |
| `--interactive` | Keeps the full terminal stack even with `--bg`; foreground runs receive it automatically. | `aiur run --bg --interactive` |
| `--headless` | Omits terminal-only work. The launcher supplies it for `--bg` unless `--interactive` was given. | `aiur run --headless` |
| `--no-dashboard` | Disables the HTTP listener in foreground or background mode. It is rejected when Remote Control is configured or activated, because Remote Control needs the lifecycle-hook listener. | `aiur --bg --no-dashboard` |
| `--host HOST` | Dashboard bind host. Without it, the launcher uses a Tailscale IPv4 address only when credentials are set, otherwise `127.0.0.1`. | `aiur --host 127.0.0.1` |
| `--port N` | Dashboard port. `0`, the default, asks the OS for a free port. | `aiur --port 4000` |
| `--logs-root PATH` | Stores this run's logs below an absolute expansion of `PATH`. | `aiur --logs-root ./logs` |
| `--max-agents N` | Positive launch-time concurrency override. It is an upper request, not a guarantee: configuration state caps can still lower effective capacity. | `aiur --max-agents 4` |
| `--pause` | Starts globally paused, so no agents are provisioned until `aiur resume`. | `aiur --pause` |
| `--debug` | Launcher convenience flag that enables durable debug logging and chat-pane recording. It is consumed by the launcher, not the release parser. | `aiur run --debug` |
| `--i-understand-that-this-will-be-running-without-the-usual-guardrails` | Required by the release parser, but injected by the launcher when absent. You normally do not need to type it. | `aiur run` |
| `--version` | Prints the release version and exits without claiming the running node. | `aiur --version` |
| `aiur help` | Prints launcher usage. `-h`, `-help`, `--h`, and `--help` are equivalent aliases. | `aiur help` |

`--no-dashboard` is independent of foreground/background mode. A dashboard bound beyond loopback needs `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`; writable dashboards need those credentials too. See [Configuration](/reference/configuration).

## Initialize and queue

<!-- cli-command: --only -->

| Command | Arguments and behavior | Runnable example |
| --- | --- | --- |
| `aiur init` | Interactive setup. It discovers toolchains, writes `.aiur/config`, `.aiur/hooks`, and `.aiur/prompt.md`, can prepare prewarm state, and creates the repository state-node layout. | `aiur init` |
| `aiur init --force` | Re-runs setup while preserving sibling scaffold files. | `aiur init --force` |
| `aiur --todo ID...` | Marks one or more numeric GitHub issue IDs as queued. IDs can be space or comma separated. This is a one-shot operation and does not start the daemon. | `aiur --todo 142 143` |
| `aiur --todo ID... --only` | Queues the requested issues and dequeues other pending tickets. It does not interrupt tickets already in another active lifecycle state. Treat it as a deliberate queue replacement. | `aiur --todo 142,143 --only` |

## Inspect a running daemon

<!-- cli-command: status -->
<!-- cli-command: usage -->
<!-- cli-command: agents -->
<!-- cli-command: alerts -->
<!-- cli-command: watch -->

These commands contact the instance keyed for the current project. They do not rebuild an existing local release when invoked through `aiurdev`.

| Command | Default and interaction | Runnable example |
| --- | --- | --- |
| `aiur status` | Prints visible ticket state, global-pause status, comment-trust state, and build-gate health. Takes no arguments. | `aiur status` |
| `aiur agents` | One line per active agent with state, runtime, and current activity. It is the terminal-friendly headless equivalent of the board. | `aiur agents` |
| `aiur usage` | Prints observed provider-limit headroom and observation age. An unobserved provider is `unknown`, not zero. | `aiur usage` |
| `aiur alerts` | Emits newline-delimited JSON alert history. | `aiur alerts` |
| `aiur alerts --needs-attention` | Filters alerts to conditions requiring Executor attention. | `aiur alerts --needs-attention` |
| `aiur watch` | One-shot server-side fleet board. `--changes` is the default and prints only state-level changes since the prior invocation. | `aiur watch` |
| `aiur watch --full` | Prints every active row. | `aiur watch --full` |
| `aiur watch --changes` | Explicit default delta-only view. | `aiur watch --changes` |
| `aiur watch --once` | Accepted no-op spelling for a one-shot view. | `aiur watch --once` |
| `aiur watch --interval SECONDS` | Re-renders the selected watch view until interrupted; seconds must be positive. | `aiur watch --full --interval 5` |

## Control agents and capacity

<!-- cli-command: set -->
<!-- cli-command: pause -->
<!-- cli-command: resume -->
<!-- cli-command: message -->

| Command | Arguments and interaction | Runnable example |
| --- | --- | --- |
| `aiur set max-agents N` | Sets a positive runtime concurrency cap without changing configuration. Existing work drains down when the cap is lowered. Configured per-state limits can still be lower. | `aiur set max-agents 6` |
| `aiur pause` | Enables the global pause switch for the current daemon. It holds the whole daemon and prevents new provisioning. A bare pause is not durable across restart; use `--pause` on the next launch when that behavior is needed. [#1479](https://github.com/aiur-team/aiur/issues/1479) tracks durable global-pause state. | `aiur pause` |
| `aiur resume` | Disables the global pause switch. | `aiur resume` |
| `aiur pause ID...` | Cooperatively pauses selected issue IDs at a safe boundary. IDs may be comma or space separated. | `aiur pause 142 143,144` |
| `aiur resume ID...` | Resumes selected individually paused issues. It cannot override an active global pause. | `aiur resume 142` |
| `aiur pause --all` / `aiur resume --all` | Applies the individual pause/resume action to all applicable active tickets. These forms are distinct from bare global pause/resume. | `aiur pause --all` |
| `aiur message ID TEXT...` | Queues Executor text for a running agent using its native delivery queue. Quote multi-word text. | `aiur message 142 "Please address the latest review"` |

In the foreground board, `j`/`k` or arrows select rows, `Enter` opens the selected chat, `Shift+Enter` or `O` opens another pane, space toggles the selected ticket pause, left/right adjust the runtime max-agent cap, `r` toggles Remote Control, `v` changes pane orientation, `?` shows help, and `q` exits the board. The dashboard sidebar has its own hide/show navigation toggle; it persists across dashboard navigation.

## Executor events

<!-- cli-command: executor-listen -->
<!-- cli-command: executor-emit -->
<!-- cli-command: executor-subscribe -->
<!-- cli-command: executor-unsubscribe -->
<!-- cli-command: executor-subscriptions -->

Executor event bindings are persistent topic-pattern subscriptions. Topic patterns use `*` for one segment and `#` for zero or more segments.

| Command | Default and interaction | Runnable example |
| --- | --- | --- |
| `aiur executor-listen --topic PATTERN` | Streams matching Executor events as JSON lines. The default pattern is `executor.#`. | `aiur executor-listen --topic 'ticket.*.agent.#'` |
| `aiur executor-emit TOPIC --payload JSON` | Publishes a JSON-object Executor event. `--payload` is required. | `aiur executor-emit executor.note --payload '{"text":"triage complete"}'` |
| `aiur executor-subscribe PATTERN` | Persists an Executor event subscription. | `aiur executor-subscribe 'ticket.142.#'` |
| `aiur executor-unsubscribe PATTERN` | Removes that exact persistent subscription. | `aiur executor-unsubscribe 'ticket.142.#'` |
| `aiur executor-subscriptions` | Lists persistent Executor subscriptions. | `aiur executor-subscriptions` |

## Maintenance

<!-- cli-command: cleanup-stale -->
<!-- cli-command: stop -->

| Command | Default and interaction | Runnable example |
| --- | --- | --- |
| `aiur cleanup-stale` | Reports and reaps stale manual-smoke resources for this launcher identity. | `aiur cleanup-stale` |
| `aiur cleanup-stale --dry-run` | Reports stale manual-smoke resources without reaping them. | `aiur cleanup-stale --dry-run` |
| `aiur stop` | Stops the matching daemon, its tmux lifetime session, and tracked agents. It is idempotent when no matching daemon is running. | `aiur stop` |
| `scripts/aiurdev build` | Development-only: force-rebuilds the local application and release while keeping dependency artifacts. | `scripts/aiurdev build` |
| `scripts/aiurdev build --deps` | Development-only: additionally removes the development build artifacts before rebuilding. | `scripts/aiurdev build --deps` |

`aiurdev` also has an Executor-root manual-test harness: `--test`, `--test3`, `--allow-remote`, and `--clear`. They are not installed-product commands. `--test` and `--test3` reset pinned GitHub sandbox tickets; `--clear` requires debug mode and clears prior debug logs. Agent workspaces deliberately reject the test flags, so do not use them for ordinary local verification.

## Mechanical coverage audit

Run this after changing this page or the launcher:

```bash
cd website/docs-app
npm run check:cli-reference
```

The check reads the shared launcher dispatch, checks every command marker above, and checks the release parser and launcher-only run flags. It fails when a current command or flag is missing from this reference. The release's `--help` is also an input, but not the sole authority: `usage` and `cleanup-stale` are dispatched by the current launcher even though the help banner has not yet listed them.

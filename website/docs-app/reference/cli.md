# CLI and control commands

`aiur` is the installed command. `scripts/aiurdev` is its development wrapper: both dispatch to the same launcher engine and have the same command surface. `aiurdev` selects the local release and rebuilds it when necessary. Its only command exception is `aiurdev build [--deps]`, which force-rebuilds the local release and does not exist in an installed `aiur`. The development-only harness flags are listed in [Maintenance](#maintenance).

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
<!-- cli-flag: --bg -->
<!-- cli-flag: --interactive -->
<!-- cli-flag: --headless -->
<!-- cli-flag: --no-dashboard -->
<!-- cli-flag: --host -->
<!-- cli-flag: --port -->
<!-- cli-flag: --logs-root -->
<!-- cli-flag: --max-agents -->
<!-- cli-flag: --pause -->
<!-- cli-flag: --debug -->
<!-- cli-flag: --i-understand-that-this-will-be-running-without-the-usual-guardrails -->
<!-- cli-flag: --version -->

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
| `--logs-root PATH` | Stores this run's logs below an absolute expansion of `PATH`. Without it, Aiur mints `~/.aiur/logs/<session-id>/` for the daemon log root. | `aiur --logs-root ./logs` |
| `--max-agents N` | Positive launch-time concurrency override. It wins over `agent.max_concurrent_agents`; exceeding the configured cap prints a warning naming both values. It is still an upper request, not a guarantee: the AIMD load envelope, paused reservations, and per-state caps can lower effective capacity. | `aiur --max-agents 4` |
| `--pause` | Starts globally paused, so no agents are provisioned until `aiur resume`. | `aiur --pause` |
| `--debug` | Launcher convenience flag that enables durable debug logging and chat-pane recording. It is consumed by the launcher, not the release parser. | `aiur run --debug` |
| `--i-understand-that-this-will-be-running-without-the-usual-guardrails` | Required by the release parser, but injected by the launcher when absent. You normally do not need to type it. | `aiur run` |
| `--version` | Prints the release version and exits without claiming the running node. | `aiur --version` |
| `aiur help` | Prints launcher usage. `-h`, `-help`, `--h`, and `--help` are equivalent aliases. | `aiur help` |

`--no-dashboard` is independent of foreground/background mode. A dashboard bound beyond loopback needs `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`; writable dashboards need those credentials too. See [Configuration](/reference/configuration).

## Initialize and queue

<!-- cli-command: --only -->
<!-- cli-flag: --force -->
<!-- cli-flag: --todo -->
<!-- cli-flag: --only -->

| Command | Arguments and behavior | Runnable example |
| --- | --- | --- |
| `aiur init` | Interactive setup. It asks for tracker and bot identity, agents, routing and fallback, permissions, workspace, concurrency and turn limits, polling, prompt path, prewarm, and alerts. | `aiur init` |
| `aiur init --force` | Re-runs setup while preserving sibling scaffold files. | `aiur init --force` |
| `aiur --todo ID...` | Marks one or more numeric GitHub issue IDs as queued. IDs can be space or comma separated. This is a one-shot control operation: it does not start a daemon, and it requires the keyed daemon to already be running. A stopped daemon (or one that exited unexpectedly) fails with recovery guidance instead of queuing. | `aiur --todo 142 143` |
| `aiur --todo ID... --only` | Queues the requested issues and dequeues other pending tickets. It does not interrupt tickets already in another active lifecycle state. Treat it as a deliberate queue replacement. Cleanup is GitHub-only, is skipped entirely if any requested target fails, is capped at 50 candidates per run, and stops after three consecutive GitHub rate-limit failures. | `aiur --todo 142,143 --only` |

On a fresh repository setup, `init` writes the config, prompt, hooks, alerts, and prewarm files; it can set up GitHub `.env`, offer a `.gitignore` entry, configure CODEOWNERS, detect agent CLIs, and create tracker labels. It runs the first base build and creates state-node build data only when prewarm is enabled and the tracker has a repository.

## Inspect a running daemon

<!-- cli-command: status -->
<!-- cli-command: usage -->
<!-- cli-command: agents -->
<!-- cli-command: alerts -->
<!-- cli-command: watch -->
<!-- cli-flag: --needs-attention -->
<!-- cli-flag: --full -->
<!-- cli-flag: --changes -->
<!-- cli-flag: --once -->
<!-- cli-flag: --interval -->

These commands contact the instance keyed for the current project. Through `aiurdev`, `status`, `agents`, `alerts`, and the other pure-control commands use the existing release; `usage` and `watch` are not on that fast path and can rebuild a stale local release before they run.

| Command | Default and interaction | Runnable example |
| --- | --- | --- |
| `aiur status` | Prints visible ticket state, global-pause status, comment-trust state, and build-gate health. A final `AGENTS occupied/max (binding: ...)` line names the capacity bound actually limiting the fleet: the configured `agent.max_concurrent_agents`, the AIMD load envelope, paused reservations, ticket supply, or the session `--max-agents` override; `none` means nothing is binding. Takes no arguments. | `aiur status` |
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
<!-- cli-flag: --all -->

| Command | Arguments and interaction | Runnable example |
| --- | --- | --- |
| `aiur set max-agents N` | Sets a positive runtime concurrency cap without changing configuration. Existing work drains down when the cap is lowered. Configured per-state limits can still be lower. | `aiur set max-agents 6` |
| `aiur pause` | Enables the global pause switch for the daemon. It holds the whole daemon and prevents new provisioning. The switch is durable: it persists across a restart with recorded provenance, and a restart that cannot read the persisted state fails closed, starting paused rather than releasing a fleet an operator deliberately parked. `aiur resume` lifts it. | `aiur pause` |
| `aiur resume` | Disables the global pause switch. | `aiur resume` |
| `aiur pause ID...` | Cooperatively pauses selected issue IDs at a safe boundary. IDs may be comma or space separated. | `aiur pause 142 143,144` |
| `aiur resume ID...` | Resumes selected paused issues, or starts an active ticket whose agent is idle. It cannot override an active global pause; terminal or non-active targets are rejected. | `aiur resume 142` |
| `aiur pause --all` / `aiur resume --all` | Applies the individual pause/resume action to all applicable active tickets. These forms are distinct from bare global pause/resume. | `aiur pause --all` |
| `aiur message ID TEXT...` | Requires a numeric issue ID and 1 to 8,000 nonblank characters. It base64-encodes text for the RPC, preserving quotes, backslashes, interpolation-looking text, and newlines. Delivery tries an in-turn interrupt, then queues for the next turn when interruption is unavailable. It can resume paused work or reactivate deactivated work; it exits nonzero for an unavailable control plane or a terminal/nonexistent target. | `aiur message 142 "Please address the latest review"` |

In the foreground board, `j`/`k` or arrows select rows, `Enter` opens the selected chat, `Shift+Enter` or `O` opens another pane, space toggles the selected ticket pause, left/right adjust the runtime max-agent cap, `r` toggles Remote Control, `v` changes pane orientation, `?` shows help, and `q` exits the board. The dashboard sidebar has its own hide/show navigation toggle; it persists across dashboard navigation.

## Executor events

<!-- cli-command: executor-listen -->
<!-- cli-command: executor-emit -->
<!-- cli-command: executor-subscribe -->
<!-- cli-command: executor-unsubscribe -->
<!-- cli-command: executor-subscriptions -->
<!-- cli-flag: --topic -->
<!-- cli-flag: --payload -->

Executor event bindings are persistent topic-pattern subscriptions. Every Executor topic starts with `executor.`; a pattern must start with that prefix and may use `*` for one segment and `#` for zero or more segments. Patterns reject a leading or trailing dot and empty segments, so a `ticket.*.agent.#` pattern is not a valid Executor subscription.

| Command | Default and interaction | Runnable example |
| --- | --- | --- |
| `aiur executor-listen --topic PATTERN` | Streams matching Executor events as JSON lines. It persists the supplied pattern, listens across every stored subscription, replays journal events after the durable cursor, then streams live events; it has no one-shot timeout. The default pattern is `executor.#`. | `aiur executor-listen --topic 'executor.decision.#'` |
| `aiur executor-emit TOPIC --payload JSON` | Publishes a JSON-object Executor event on a topic that must start with `executor.`. `--payload` is required. | `aiur executor-emit executor.note --payload '{"text":"triage complete"}'` |
| `aiur executor-subscribe PATTERN` | Persists an Executor event subscription. | `aiur executor-subscribe 'executor.note'` |
| `aiur executor-unsubscribe PATTERN` | Removes that exact persistent subscription. | `aiur executor-unsubscribe 'executor.note'` |
| `aiur executor-subscriptions` | Lists persistent Executor subscriptions. | `aiur executor-subscriptions` |

## Maintenance

<!-- cli-command: cleanup-stale -->
<!-- cli-command: stop -->
<!-- cli-dev-command: build -->
<!-- cli-flag: --dry-run -->
<!-- cli-flag: --deps -->
<!-- cli-flag: --test -->
<!-- cli-flag: --test3 -->
<!-- cli-flag: --allow-remote -->
<!-- cli-flag: --clear -->
<!-- cli-planned-command: findings -->
<!-- cli-planned-flag: --unfiled -->

| Command | Default and interaction | Runnable example |
| --- | --- | --- |
| `aiur cleanup-stale` | Reports and reaps stale manual-smoke resources for this launcher identity. | `aiur cleanup-stale` |
| `aiur cleanup-stale --dry-run` | Reports stale manual-smoke resources without reaping them. | `aiur cleanup-stale --dry-run` |
| `aiur stop` | Stops the matching daemon, its tmux lifetime session, and tracked agents. A clean nothing-to-stop invocation exits 1 with `nothing stopped`. A daemon that exited unexpectedly is reported separately with orphan-recovery guidance and is reaped rather than treated as a clean stop. | `aiur stop` |
| `scripts/aiurdev build` | Development-only: force-rebuilds the local application and release while keeping dependency artifacts. | `scripts/aiurdev build` |
| `scripts/aiurdev build --deps` | Development-only: additionally removes the development build artifacts before rebuilding. | `scripts/aiurdev build --deps` |

The following `aiurdev` harness flags are development-only. They are not part of installed `aiur`, and agent workspaces reject the reset paths.

| Command or flag | Default and interaction | Runnable example |
| --- | --- | --- |
| `scripts/aiurdev --test` | Destructive Executor-root manual harness. It enables `--debug` and `--clear` (deleting every entry under the applicable logs root), stops the keyed live daemon, then force-resets one pinned GitHub sandbox ticket before a foreground run. Agent workspaces reject this path. | `scripts/aiurdev --test` |
| `scripts/aiurdev --test3` | Destructive Executor-root manual harness. It enables `--debug`, `--clear`, and `--allow-remote`, deletes every entry under the applicable logs root, stops the keyed live daemon, force-resets the three-ticket blocker chain, then starts its timer and foreground run. Agent workspaces reject this path. | `scripts/aiurdev --test3` |
| `scripts/aiurdev --allow-remote` | Allows the reset harness to include its remote-agent path. It matters only with `--test` or `--test3`; alone it has no effect. `--test3` supplies it automatically. | `scripts/aiurdev --test --allow-remote` |
| `scripts/aiurdev --clear` | Deletes every entry under the applicable logs root (`~/.aiur/logs/`, or the agent IR sandbox log parent) before launch, not merely prior debug logs. It requires `--debug`; either test harness enables both automatically. Do not combine it with a session whose logs must be retained. | `scripts/aiurdev --debug --clear` |

Control commands are one-shot RPCs into the keyed daemon. By default each waits up to 10 seconds; on timeout the helper process and its descendants are terminated and the command exits 124 with a scheduler-saturation hint. A non-zero exit can also mean the daemon is down: `status` distinguishes a clean stop from a recorded crash and tells you to run `aiur stop` to reap orphaned agents. `executor-listen` is the exception: it streams without a one-shot timeout.

`scripts/aiurdev` refuses every invocation while `$TMUX` is set, because the daemon runs its own tmux on a dedicated socket. Launch commands (`aiur`, `aiur run`, `aiur --bg`, and config-path runs) require the repository-pinned opencode install; control and utility commands use the existing release and do not.

Aiur has no `findings` command yet. Until [#1464](https://github.com/aiur-team/aiur/issues/1464) ships its planned `aiur findings --unfiled` query, the Executor writes deferred findings directly to `~/.aiur/repo/<owner>/<repo>/meta/findings.ndjson`.

## Mechanical coverage audit

Run this after changing this page or the launcher:

```bash
cd website/docs-app
npm run check:cli-reference
```

The check derives commands from the shared launcher dispatch cases and flags from the release parser, the control handlers' argument-parsing arms, and the dev shim's own flag parser. Its exact command and flag markers reject both missing and stale entries, and every derived item must have a complete table row with syntax, behavior, and a runnable example. The development-only `build` command is audited in both directions against `scripts/aiurdev`, and the deliberately unavailable `findings --unfiled` interface is pinned as a planned exception so no other stale token can ride its exception. The release's `--help` is also an input, but not the sole authority: `usage` is dispatched by the current launcher even though the help banner does not list it.

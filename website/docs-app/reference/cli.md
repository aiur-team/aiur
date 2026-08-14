# CLI and control commands

`aiur` is the installed CLI. `scripts/aiurdev` rebuilds a local development release when needed, then executes the same launcher engine. Apart from `aiurdev build` and the development smoke-harness flags below, they are one CLI surface, not two products.

Use the command from the repository that owns the run. An instance is keyed to that project, so control commands address that repository's daemon.

## What the CLI does

The CLI is the operator's primary surface. It starts and stops runs, drives the fleet, and reads back live state — the dashboard renders the same facts in a browser. In practice the CLI covers four jobs:

- **Start a run.** `aiur` launches a foreground run with the interactive terminal board; `aiur --bg` runs headless with no agent-list or chat panes. Foreground is for watching and chatting with agents directly; background is for unattended operation.
- **Inspect live state.** `status`, `agents`, `watch`, `alerts`, and `usage` report the fleet, capacity, alerts, and provider meters from the running daemon without changing anything.
- **Operate the fleet.** `set max-agents`, `pause`, `resume`, `message`, and `stop` steer the run while it is live — raise or lower the concurrency ceiling, hold the fleet, resume a paused ticket, send Executor text into an agent's queue, or shut the daemon down.
- **Read and act on durable records.** `commands` exposes the decision inbox, `executor-*` commands subscribe to and emit Executor events, and `findings` reads the findings ledger.

The two launch shapes matter for who is driving. `aiur` runs the [TUI](/guide/tui) — the agent-list board and chat panes — for a human watching a terminal. **Background mode (`aiur --bg`) exists so an agent Executor can drive Aiur** with no board or panes: the dashboard stays up and every command below reads and writes the exact same live state through the detached daemon, so an agent can operate the run end to end over the CLI alone.

## Start, initialize, and queue

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur` <!-- cli-command: run --> | Starts a foreground interactive run. The launcher supplies a lower-precedence Tailscale-or-loopback host default, interactive UI, and required guardrail acknowledgement when absent. | `aiur` |
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

Foreground mode has the terminal board and chat panes. `--bg` is headless but still starts the dashboard unless `--no-dashboard` is passed. A configured `server.host` wins over the launcher's default; `--host` wins over both. The default is loopback, or an authenticated Tailscale address when one is safely available. Startup output reports both the usable dashboard URL and its effective bind host and port.

## Inspect and operate a running daemon

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur help` <!-- cli-command: help --> | Prints the current launcher usage. | `aiur help` |
| `aiur status` <!-- cli-command: status --> | Shows daemon and capacity status, including `AGENTS occupied/max (binding: ...)`. The binding is `config max_concurrent_agents`, `AIMD envelope`, `paused reservations`, `ticket supply`, `session max_concurrent_agents`, or `none`. `ticket supply` means no queued ticket is available, not that the configured cap is zero. | `aiur status` |
| `aiur usage` <!-- cli-command: usage --> | Prints the current provider-meter observations and their known headroom. | `aiur usage` |
| `aiur agents` <!-- cli-command: agents --> | Prints each active agent's state and current activity. | `aiur agents` |
| `aiur units` <!-- cli-command: units --> | Reads the Dashboard Units projection. Choose `--scope live\|unfinished\|all\|none`, repeat `--condition active\|alert\|paused\|queued\|finished`, choose `--format auto\|table\|records`, or add `--json`. | `aiur units --scope unfinished --condition active` |
| `aiur units --condition alert` <!-- cli-flag: --condition --> | Repeats to require any of the selected Unit conditions. | `aiur units --condition alert --condition paused` |
| `aiur units --format records` <!-- cli-flag: --format --> | Chooses `auto`, `table`, or line-oriented `records` output. | `aiur units --format records` |
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
| `aiur restart` <!-- cli-command: restart --> | Stops the running session, refreshes the release, and starts it again detached. The refresh runs between the stop and the start, so the new daemon boots on current code. Under `scripts/aiurdev` the refresh is the same build-if-stale step a normal dev launch performs; the installed `aiur` runs a pinned release and has nothing to build, so its restart is a plain bounce. A daemon that was already stopped is simply started. A failed rebuild aborts before the start and leaves the daemon stopped, and says so. | `aiur restart` |
| `aiur restart --no-build` <!-- cli-flag: --no-build --> | Bounces the daemon on whatever release is already on disk. Use it for a fast restart, or to bounce without taking uncommitted source edits live. It has no effect on the installed `aiur`, which never builds. | `aiur restart --no-build` |
| `aiur cleanup-stale` <!-- cli-command: cleanup-stale --> | Lists and reaps stale manual-smoke processes and sockets. | `aiur cleanup-stale` |
| `aiur cleanup-stale --dry-run` <!-- cli-flag: --dry-run --> | Reports stale leftovers without reaping them. | `aiur cleanup-stale --dry-run` |

## Dashboard page commands

`aiur units`, `aiur commands`, `aiur build-orders`, and `aiur analytics` are read-only terminal forms of the corresponding Dashboard pages. They read the page’s projection/provider rather than independently polling GitHub or treating `/api/v1/state` as the source of truth.

| Command | Page view and important inputs | Example |
| --- | --- | --- |
| `aiur units` | Filtered Units catalog; use `--scope`, repeated `--condition`, `--format`, or `--json`. | `aiur units --scope unfinished --condition alert --json` |
| `aiur commands [decision-id]` | Durable decision inbox, or one selected decision. Use `--filter all\|open\|blocking\|resolved`, `--blocking`, `--ticket`, `--search`, `--cursor`, `--limit`, and `--json`. `--ticket` and `--search` require `--filter all`. | `aiur commands --filter blocking --json` |
| `aiur build-orders [root]` <!-- cli-command: build-orders --> | Build Order catalog without a root; one root adds graph, execution, and activity detail. | `aiur build-orders 1567 --json` |
| `aiur analytics` <!-- cli-command: analytics --> | Analytics snapshot. Choose `--range run\|full`, an ISO-8601 `--since`/`--until` window, an optional numeric `--build-order`, or `--json`. | `aiur analytics --range full --build-order 1567 --json` |
| `aiur analytics --range full` <!-- cli-flag: --range --> | Selects the current run or all retained analytics observations. | `aiur analytics --range full` |
| `aiur analytics --since 2026-08-01T00:00:00Z` <!-- cli-flag: --since --> | Sets the inclusive ISO-8601 start of an analytics window. | `aiur analytics --since 2026-08-01T00:00:00Z` |
| `aiur analytics --until 2026-08-02T00:00:00Z` <!-- cli-flag: --until --> | Sets the exclusive ISO-8601 end of an analytics window. | `aiur analytics --until 2026-08-02T00:00:00Z` |
| `aiur analytics --build-order 1567` <!-- cli-flag: --build-order --> | Limits analytics to one numeric Build Order root. | `aiur analytics --build-order 1567` |

### Output contract

Every `--json` result is one versioned envelope with `schema_version`, `page`, `snapshot.captured_at`, `request`, `sources`, `data`, and `auxiliary`. `snapshot.captured_at` is when the command ran; it is not a claim that every source was observed then.

Each independently-read source reports its `state`, `observed_at`, `age_ms`, `freshness`, `partial`, and machine-readable `reasons`. Human output starts with that capture time and prints the same labelled source state and age before its values. This is intentional: a number without an observation age is not actionable.

Known absence stays explicit. A source that is unavailable, stale, partial, invalid, or has an unknown observation time remains a `null` or a field-level status in JSON and a labelled warning in human output; it never becomes `0`, `[]`, or `{}` merely because the command could not measure it. An empty collection means an observed empty source or a documented, valid zero-result filter — not an outage. `auxiliary` holds separately-derived values such as provider spend and preserves their own source metadata instead of merging an estimate into the page’s primary data.

## Decisions, Executor events, and findings

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur ask "Title"` <!-- cli-command: ask --> | Creates a durable operator request for the current repository. Add `--body` or `--body-file`, `--urgency low\|normal\|high`, and `--blocking` as needed. | `aiur ask "Approve production cutover" --blocking --urgency high` |
| `aiur ask "Title" --body "Context"` <!-- cli-flag: --body --> | Stores short supporting Markdown in the ask. | `aiur ask "Approve production cutover" --body "Production freeze ends today."` |
| `aiur ask "Title" --body-file request.md` <!-- cli-flag: --body-file --> | Reads the supporting body from a UTF-8 file. | `aiur ask "Approve production cutover" --body-file request.md` |
| `aiur ask "Title" --urgency high` <!-- cli-flag: --urgency --> | Classifies the request as `low`, `normal`, or `high`. | `aiur ask "Approve production cutover" --urgency high` |
| `aiur ask --done ASK-ID` <!-- cli-flag: --done --> | Resolves one open ask; `--note` records the resolution context. | `aiur ask --done ask_123 --note "Approved by release manager"` |
| `aiur ask --done ASK-ID --note "Approved"` <!-- cli-flag: --note --> | Saves the optional resolution context with a completed ask. | `aiur ask --done ask_123 --note "Approved by release manager"` |
| `aiur asks` <!-- cli-command: asks --> | Lists open asks by default. Use `--all` to include resolved records and `--json` for the durable rows. | `aiur asks --all --json` |
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

An open **blocking** ask is also printed by plain `aiur status`; no extra flag is required. That keeps a durable request in the normal operating view instead of hiding it in a ledger that nobody reads.

## Operational facts that change an incident response

- **Dispatch needs `agent:todo`.** An issue can be open, labelled, eligible, and unblocked yet still not dispatch until it carries `agent:todo`. If `aiur status` says `AGENTS 0/32 (binding: ticket supply)`, it means no queued ticket is available — not that no work exists. Queue it with `aiur --todo <id>` or add the label.
- **Global pause is durable.** Bare `aiur pause` is a fleet-wide provisioning switch and survives restart. A restarted fleet can therefore be correctly silent; use `aiur status` and `aiur resume` rather than assuming the daemon lost work.
- **CI readiness uses an operator-only token.** Set `AIUR_CI_READINESS_TOKEN` in the daemon’s environment with GitHub `workflow` scope, then restart the daemon. The daemon reads it for workflow inspection and removes it from every agent shell; do not put it in an agent workspace or prompt.
- **A base refresh affects approval ownership.** With `require_last_push_approval`, an Executor who refreshes a stale PR branch becomes its last pusher and cannot satisfy the required approval. Route the fetch/merge/push through that ticket’s agent identity instead; then obtain or retain review under the repository’s normal rules.

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

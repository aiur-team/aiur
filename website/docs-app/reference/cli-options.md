# CLI launch options

This table lists flags accepted by the release parser and shared launcher. See the [CLI reference](/reference/cli) for command-specific behavior and examples.

### Global launch options

| Syntax | Default or important interaction | Runnable example | <!-- generated-reference:cli-run-options -->
| --- | --- | --- |
| `aiur --all` | Includes all matching results instead of the default subset. | `aiur --all` |
| `aiur --bg` | Starts detached headless execution. Against an existing live session it exits successfully and names bare `aiur` as the attach command. A default headless session has no agent-list or chat panes; use the dashboard or control commands. | `aiur --bg` |
| `aiur --blocking` | Marks a supported command as blocking. | `aiur --blocking` |
| `aiur --body TEXT` | Uses the supplied text as a command body. | `aiur --body 'Investigate this issue'` |
| `aiur --body-file PATH` | Reads a command body from a file. | `aiur --body-file request.md` |
| `aiur --debug` | Enables debug logs and durable chat-pane recording for this run. Analytics capture does not depend on `--debug`. | `aiur --debug` |
| `aiur --digest` | Prints the compact digest for the current run. | `aiur --digest` |
| `aiur --dir PATH` | Selects a working directory for a supported command. | `aiur --dir ./project` |
| `aiur --done TEXT` | Adds completion text to a supported command. | `aiur --done 'Merged'` |
| `aiur --executor` | Marks the run as Executor-owned and registers its renewing principal in `executor-roster`. Recording is **not** gated on this flag: every run arms the supervised `executor.#` listener and the wake inbox, so PR-lifecycle, CI and attention records exist for a later agent to replay. What the flag adds is authority — created and deferred Commands are raised as needs-attention alerts only on an Executor-owned run. On startup it also records an informational, retrospective daemon heartbeat gap when the durable lifecycle journal confirms a clean stop or an unclosed prior start. This is not live monitoring: no alert is emitted while Aiur is stopped; the notice appears on the next Executor startup. `LISTENER absent` is therefore always a fault. | `aiur --bg --executor` |
| `aiur --harness NAME` | Legacy parser option; does not change the configured agent harness. Use the workflow agent configuration. | `aiur --harness codex` |
| `aiur --headless` | Requests no terminal UI. Background launch injects it unless `--interactive` is present. | `aiur run --headless` |
| `aiur --host 127.0.0.1` | Overrides the dashboard bind host. A non-loopback host requires dashboard credentials. | `aiur --host 127.0.0.1` |
| `aiur --i-understand-that-this-will-be-running-without-the-usual-guardrails` | Required by the release parser; the launcher inserts it for normal run commands. | `aiur run --i-understand-that-this-will-be-running-without-the-usual-guardrails` |
| `aiur --interactive` | Requests the terminal UI, including from a background launch. | `aiur --bg --interactive` |
| `aiur --json` | Prints supported command output as JSON. | `aiur --json` |
| `aiur --logs-root /var/log/aiur` | Overrides the daemon log root for this launch. | `aiur --logs-root /var/log/aiur` |
| `aiur --max-agents 6` | Launch-only session cap. It wins over `agent.max_concurrent_agents`; Aiur warns when it exceeds that setting. `status` identifies the active binding. | `aiur --max-agents 6` |
| `aiur --no-dashboard` | Suppresses the dashboard listener in foreground or background mode. It is rejected for Remote Control because its lifecycle hooks need the listener. | `aiur --bg --no-dashboard` |
| `aiur --note TEXT` | Attaches a note to a supported command. | `aiur --note 'Follow up tomorrow'` |
| `aiur --open` | Opens the selected result in the configured browser. | `aiur --open` |
| `aiur --pause` | Cold-starts with the global provisioning switch paused. | `aiur --pause` |
| `aiur --port 4000` | Overrides the HTTP port. `0` lets the OS choose a free port. | `aiur --port 4000` |
| `aiur --purge` | Removes persisted credentials for a supported account command. | `aiur accounts logout codex default --purge` |
| `aiur --record PATH` | Writes a recording to the selected path. | `aiur --record run.jsonl` |
| `aiur --repo OWNER/REPO` | Selects the repository for a supported tracker command. | `aiur --repo aiur-team/aiur` |
| `aiur --scope feature` | Filters a supported ticket listing by scope. | `aiur --scope orchestration` |
| `aiur --slugs` | Renders ticket identifiers as tracker slugs where supported. | `aiur --slugs` |
| `aiur --todo 142 --only` | Queues the named IDs and asks GitHub to remove `agent:todo` from other pending tickets. It is GitHub-only, is bounded to 50 cleanup targets, and stops after three consecutive rate-limit failures. Removing `agent:todo` from a promoted queue member creates an external hold, cleared with `aiur queue release`. Cleanup is skipped if a requested ID fails, so the operation does not silently dequeue work after a bad request. | `aiur --todo 142 --only` |
| `aiur --todo 142 143` | Requires a running daemon and one or more numeric IDs, with commas also accepted. A stopped daemon exits nonzero. | `aiur --todo 142,143` |
| `aiur --unfiled` | Includes tickets without an issue identifier in supported listing commands. | `aiur --unfiled` |
| `aiur --urgency LEVEL` | Sets urgency for a supported command. | `aiur --urgency high` |
| `aiur --version` | Prints both the release version and shell dispatcher version without contacting or claiming a running daemon. If they differ, update `aiur-cli` before trusting that newer subcommands are available. | `aiur --version` |
| `aiur init --force` | Recreates generated configuration for the location you choose at the first prompt; picking repo-local leaves an existing `~/.aiur/config` untouched. `--force` explicitly re-runs setup choices, including recorded declines. Re-running without it preserves existing scaffold files and recorded declines. | `aiur init --force` |

---
pageClass: cli-reference
---

# CLI

`aiur` exists so an **agent can run Aiur on your behalf**.

| Design goal | Result |
| --- | --- |
| Executor access | An agent can operate a run from a terminal without asking a human to type commands. |
| Surface parity | The CLI targets feature parity with the [Dashboard](/guide/executor-control-center) and [TUI](/guide/tui). |

A human can of course type any of it. Most humans will not: they watch the TUI or the dashboard and let their Executor agent drive.

Run the command from the repository that owns the run. An instance is keyed to that project, so control commands address that repository's daemon.

## What the CLI does

| Job | Commands | Notes |
| --- | --- | --- |
| Start or attach | `aiur`, `aiur run` | Bare `aiur` attaches to this repository's live session when one exists; otherwise foreground gives the TUI board and chat panes. Background is headless unless launched with `--interactive`. |
| Inspect live state | `status`, `agents`, `watch`, `alerts`, `usage`, `github-cost`, `github-usage` | Read-only reports from the running daemon. |
| Operate the fleet | `set max-agents`, `pause`, `resume`, `message`, `reset-budget`, `stop`, `restart` | Steers a live run. |
| Mirror a dashboard page | `units`, `commands`, `build-orders`, `analytics` | Read-only terminal forms of the dashboard pages. |
| Act on durable records | `ask`, `asks`, `executor-answer`, `executor-escalate`, `executor-moot`, `executor-emit`, `executor-listen`, `findings` | Decision inbox, Executor events, and findings ledger. |
| Guard a repository | `guard-pr-deletions` | Refuses a PR with excessive untouched deletions. |

Background mode is the shape that matters for an agent Executor. `aiur --bg` starts the daemon with no board and no panes, the dashboard stays up, and every command below reads and writes the same live state through that detached daemon.

## Start, initialize, and queue

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur` | Attaches to this repository's live tmux session when one exists; otherwise starts a foreground interactive run. Attachment does not create a second run or take teardown ownership, so detaching leaves the daemon healthy. | `aiur` |
| `aiur run` | Explicit foreground launch form. `--bg` makes it headless; `--interactive` restores terminal panes in a background session. | `aiur run --bg` |
| `aiur init` | Interactive setup detects the tracker and toolchain, writes `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`, `.aiur/alerts`, and prewarm support when selected, then creates the repository state-node tree and warms the base build. It also asks whether to enable Stream Deck voice input with ElevenLabs speech-to-text; answering yes writes the `elevenlabs` section, defaulting the key to the `$ELEVENLABS_API_KEY` environment reference. A resumed `aiur init` offers the same question when the saved config predates the section. | `aiur init` |
| `aiur init --force` | Recreates generated configuration. Re-running without it preserves existing scaffold files. | `aiur init --force` |
| `aiur --todo 142 143` | Requires a running daemon and one or more numeric IDs, with commas also accepted. A stopped daemon exits nonzero. | `aiur --todo 142,143` |
| `aiur --todo 142 --only` | Queues the named IDs and asks GitHub to remove `agent:todo` from other pending tickets. It is GitHub-only, is bounded to 50 cleanup targets, and stops after three consecutive rate-limit failures. Cleanup is skipped if a requested ID fails, so the operation does not silently dequeue work after a bad request. | `aiur --todo 142 --only` |
| `aiur --bg` | Starts detached headless execution. Against an existing live session it exits successfully and names bare `aiur` as the attach command. A default headless session has no agent-list or chat panes; use the dashboard or control commands. | `aiur --bg` |
| `aiur --debug` | Enables debug logs and durable chat-pane recording for this run. | `aiur --debug` |
| `aiur --pause` | Cold-starts with the global provisioning switch paused. | `aiur --pause` |
| `aiur --max-agents 6` | Launch-only session cap. It wins over `agent.max_concurrent_agents`; Aiur warns when it exceeds that setting. `status` identifies the active binding. | `aiur --max-agents 6` |
| `aiur --interactive` | Requests the terminal UI, including from a background launch. | `aiur --bg --interactive` |
| `aiur --headless` | Requests no terminal UI. Background launch injects it unless `--interactive` is present. | `aiur run --headless` |
| `aiur --executor` | Marks the run as Executor-owned. Recording is **not** gated on this flag: every run arms the supervised `executor.#` listener and the wake inbox, so PR-lifecycle, CI and attention records exist for a later agent to replay. What the flag adds is authority — created and deferred Commands are raised as needs-attention alerts only on an Executor-owned run. `LISTENER absent` is therefore always a fault. | `aiur --bg --executor` |
| `aiur --no-dashboard` | Suppresses the dashboard listener in foreground or background mode. It is rejected for Remote Control because its lifecycle hooks need the listener. | `aiur --bg --no-dashboard` |
| `aiur --host 127.0.0.1` | Overrides the dashboard bind host. A non-loopback host requires dashboard credentials. | `aiur --host 127.0.0.1` |
| `aiur --port 4000` | Overrides the HTTP port. `0` lets the OS choose a free port. | `aiur --port 4000` |
| `aiur --logs-root /var/log/aiur` | Overrides the daemon log root for this launch. | `aiur --logs-root /var/log/aiur` |
| `aiur --i-understand-that-this-will-be-running-without-the-usual-guardrails` | Required by the release parser; the launcher inserts it for normal run commands. | `aiur run --i-understand-that-this-will-be-running-without-the-usual-guardrails` |
| `aiur --version` | Prints both the release version and shell dispatcher version without contacting or claiming a running daemon. If they differ, update `aiur-cli` before trusting that newer subcommands are available. | `aiur --version` |

| Launch choice | Behavior |
| --- | --- |
| Foreground | Shows the terminal board and chat panes. A later bare `aiur` from the same repository reattaches to that session. |
| `--bg` | Runs headlessly but keeps the dashboard unless paired with `--no-dashboard`. |
| Host precedence | `--host` wins over `server.host`, which wins over the loopback or safe Tailscale default. |
| Startup output | Reports the usable dashboard URL and effective bind host and port. |

When an unknown subcommand is routed through a release built from a checkout, Aiur also compares the dispatcher and checkout package versions. If the dispatcher is older, the error tells you to update `aiur-cli` instead of presenting the command as simply unavailable.

## Inspect and operate a running daemon

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur help` | Prints the current launcher usage. | `aiur help` |
| `aiur status` | Shows daemon and capacity status, including `AGENTS occupied/max (binding: ...)`. A CPU-corroborated load or run-queue hold includes both the pressure and reclaimable-CPU thresholds; a high local load sample alone says the daemon still corroborates CPU contention. A GitHub quota hold includes its resource, measured remaining/limit, and observation time, and becomes `github_quota stale` after two missed probes. Other bindings include `config max_concurrent_agents`, `AIMD envelope`, `paused reservations`, `ticket supply`, `session max_concurrent_agents`, or `none`; `ticket supply` means a recent poll found no queued ticket, while `has not polled yet` (with the POLL backoff countdown) is shown when the fleet is idle-backed-off or the last tracker fetch failed. When slots are free, the binding also names the effective ceiling's source (`ticket supply; ceiling: config max_concurrent_agents` vs `has not polled yet (...; ceiling: session max_concurrent_agents)`) so a restart that dropped a live `set max-agents` reads as config-sourced rather than as the operator's last command. When a build-gate lease is held or queued, `status` also prints `BUILD GATE HOLDER slot=… pid=… command="…" held=…` (and `BUILD GATE QUEUED … waiting=…`) so a pinned lease is attributable without reading process trees. | `aiur status` |
| `aiur usage` | Prints the current provider-meter observations and their known headroom. | `aiur usage` |
| `aiur github-cost` | Ranks GitHub API spend by the call site that caused it, in points and points per hour, and prints the reconciliation against the credential's own window beside it. Prints the admission ledger's retention window (one rolling hour) on the same screen, so the ledger is never reconciled against a longer `/rate_limit` span. Reads the meter the daemon already keeps and issues no GitHub request of its own. Defaults to the `graphql` budget. | `aiur github-cost` |
| `aiur github-cost --budget core` | Selects one budget: `graphql`, `core`, or `all`. The two budgets are never summed into one number because GitHub bills them separately, on separate windows. | `aiur github-cost --budget core` |
| `aiur github-cost --format records` | Chooses `auto`, `table`, or line-oriented `records` output. | `aiur github-cost --format records` |
| `aiur github-cost --json` | Emits the ranking as one versioned envelope. | `aiur github-cost --json` |
| `aiur github-usage` | Prints per-actor (daemon vs each agent workspace) GitHub usage: Core, GraphQL and `search` `used`/`limit` with reset times, read from the shared admission broker's `admissions`. Limits are request-count ceilings (the broker sees requests, not GraphQL points); `0` in the config means no ceiling. Issues no GitHub request of its own. | `aiur github-usage` |
| `aiur github-usage --json` | Emits the per-actor usage as one versioned envelope. | `aiur github-usage --json` |
| `aiur agents` | Prints each active agent's state and current activity. | `aiur agents` |
| `aiur units` | Reads the Dashboard Units projection. Choose `--scope live\|unfinished\|all\|none`, repeat `--condition active\|alert\|paused\|queued\|finished`, choose `--format auto\|table\|records`, or add `--json`. | `aiur units --scope unfinished --condition active` |
| `aiur units --condition alert` | Repeats to require any of the selected Unit conditions. | `aiur units --condition alert --condition paused` |
| `aiur units --format records` | Chooses `auto`, `table`, or line-oriented `records` output. | `aiur units --format records` |
| `aiur watch` | Shows changed fleet rows by default. | `aiur watch` |
| `aiur watch --full` | Prints all fleet rows. | `aiur watch --full` |
| `aiur watch --changes` | Makes the changed-rows default explicit. | `aiur watch --changes` |
| `aiur watch --once` | Requests the one-shot form. | `aiur watch --once` |
| `aiur watch --interval 5` | Re-renders until interrupted. The interval must be a positive number of seconds. | `aiur watch --interval 5` |
| `aiur alerts` | Shows the structured alert feed. | `aiur alerts` |
| `aiur alerts --needs-attention` | Filters to unresolved alerts requiring Executor action. | `aiur alerts --needs-attention` |
| `aiur set max-agents 6` | Changes the live session cap without editing config. The new cap applies to live state at once (`status` reflects it), and dispatch reconciles to it on the next poll cadence. It does not rewrite the next launch's config; a restart drops it, and `aiur status` then shows the ceiling as `config max_concurrent_agents` rather than as the operator's last command. | `aiur set max-agents 6` |
| `aiur pause` | Turns on the global pause switch. It stops new provisioning and cooperatively holds the fleet. The switch is persisted with its source and survives restart; a failed persisted-state read starts paused. | `aiur pause` |
| `aiur resume` | Turns off that global switch. Lifting the pause schedules a prompt poll, so a ramp resumes dispatch within one base interval rather than waiting out the idle poll backoff. | `aiur resume` |
| `aiur pause 142 143` | Requests a safe-boundary pause for named tickets. | `aiur pause 142,143` |
| `aiur pause --all` | Requests a pause for every active ticket. | `aiur pause --all` |
| `aiur resume 142` | Resumes a paused ticket, or starts an idle eligible ticket. | `aiur resume 142` |
| `aiur resume --all` | Resumes every individually paused ticket. | `aiur resume --all` |
| `aiur reset-budget 142` | Clears a named ticket's dispatch-budget latch. It does not accept `--all`; `resume` cannot clear this latch. | `aiur reset-budget 142` |
| `aiur message 142 "Check review"` | Enqueues Executor text on the native agent queue. Aiur may interrupt at a safe point, queue it for the next turn, auto-resume a paused entry, or reactivate a deactivated entry. Text must be nonblank and at most 8,000 characters. The command reports what it observed: `delivered message to #142` once the agent has claimed it, otherwise `queued message for #142 (request N); delivery is unconfirmed`. Both are successful enqueues and exit 0 — a queued message is normally claimed at the agent's next checkpoint. | `aiur message 142 "Check the latest review"` |
| `aiur stop` | Gracefully stops the BEAM and its tmux lifetime session, reaping agent process trees and workspace-rooted descendants before a final launcher backstop removes stragglers. A stopped daemon makes `stop` and `--todo` exit nonzero. | `aiur stop` |
| `aiur restart` | Stops the running session, refreshes the release, and starts it again detached. See [Restart semantics](#restart-semantics). | `aiur restart` |
| `aiur restart --no-build` | Bounces the daemon on whatever release is already on disk. Use it for a fast restart, or to bounce without taking uncommitted source edits live. It has no effect on the installed `aiur`, which never builds. It cannot rescue a failed development rebuild: that removes the incomplete release, so there is nothing left to start, and `restart` says so instead of suggesting it. | `aiur restart --no-build` |
| `aiur upgrade` | Installs the newer `aiur-cli` on your channel (`latest`, `next`, or `nightly`) and reports the version before and after, with the restart step to actually pick it up. Refuses under the `aiurdev` development launcher, for Homebrew installs (releases are npm-only right now), and while a daemon is running — pass `--force` to upgrade a live install anyway. It never downgrades: a `nightly` or `next` user is measured against their own channel, never against a lower `latest`. | `aiur upgrade` |
| `aiur upgrade --force` | Upgrades even while a daemon is running. The running daemon keeps the old code until you restart it; in-flight agents are unaffected until then. | `aiur upgrade --force` |
| `aiur cleanup-stale` | Lists and reaps stale manual-smoke processes and sockets. | `aiur cleanup-stale` |
| `aiur cleanup-stale --dry-run` | Reports stale leftovers without reaping them. | `aiur cleanup-stale --dry-run` |
| `aiur guard-pr-deletions main` | Refuses a PR that deletes more than 50 files the branch never touched. Reads the base branch from the argument or `AIUR_BASE_BRANCH`, and the branch start from `AIUR_BRANCH_START_SHA` or `refs/aiur/branch-start`. Exit 1 is a refusal, exit 2 is an unusable input such as a dirty tree, an unfetchable base, or a missing branch-start ref. | `aiur guard-pr-deletions main` |

### Restart semantics

| Restart case | Result |
| --- | --- |
| Installed `aiur` | Bounces the pinned release without building. |
| Development release | Refreshes between stop and start, then boots current code. |
| Daemon already stopped | Starts it. |
| Daemon still answers after stop | Aborts rather than rebuilding underneath it. |

Any failure after the stop, whether a failed rebuild, a failed start, or an interrupt, reports that the daemon is stopped and was not restarted.
Restart uses the same graceful agent-tree and workspace-descendant reap as `stop` before refreshing or starting the release.

Under `scripts/aiurdev`, `restart` verifies that the refreshed release came from the expected checkout and commit.

| Development refresh evidence | Result |
| --- | --- |
| Rebuild verified against the expected checkout and commit | Starts the rebuilt release. |
| Rebuild cannot be verified | Leaves the daemon stopped, exits with code 70, and names the unconfirmed builder. |
| Custom build command without verification support | Starts and reports the result as unverified. |

## Dashboard page commands

`aiur units`, `aiur commands`, `aiur build-orders`, and `aiur analytics` are read-only terminal forms of the corresponding Dashboard pages and show the same data.

| Command | Page view and important inputs | Example |
| --- | --- | --- |
| `aiur units` | Filtered Units catalog; use `--scope`, repeated `--condition`, `--format`, or `--json`. | `aiur units --scope unfinished --condition alert --json` |
| `aiur commands [decision-id]` | Durable decision inbox, or one selected decision. Use `--filter all\|open\|blocking\|resolved`, `--blocking`, `--ticket`, `--search`, `--cursor`, `--limit`, and `--json`. `--ticket` and `--search` require `--filter all`. | `aiur commands --filter blocking --json` |
| `aiur build-orders [root]` | Build Order catalog without a root; one root adds graph, execution, and activity detail. | `aiur build-orders 1567 --json` |
| `aiur analytics` | Analytics snapshot, including whole-host fleet/build pressure. Human output reports peaks, latest measured capacities, and longest live build wait; `--json` includes the timestamped pressure series. Choose `--range run\|full`, an ISO-8601 `--since`/`--until` window, an optional numeric `--build-order`, or `--json`. | `aiur analytics --range full --build-order 1567 --json` |
| `aiur analytics --range full` | Selects the current run or all retained analytics observations. | `aiur analytics --range full` |
| `aiur analytics --since 2026-08-01T00:00:00Z` | Sets the inclusive ISO-8601 start of an analytics window. | `aiur analytics --since 2026-08-01T00:00:00Z` |
| `aiur analytics --until 2026-08-02T00:00:00Z` | Sets the exclusive ISO-8601 end of an analytics window. | `aiur analytics --until 2026-08-02T00:00:00Z` |
| `aiur analytics --build-order 1567` | Limits analytics to one numeric Build Order root. | `aiur analytics --build-order 1567` |

### Output contract

Every `--json` result is one versioned envelope with `schema_version`, `page`, `snapshot.captured_at`, `request`, `sources`, `data`, and `auxiliary`. `snapshot.captured_at` is when the command ran; it is not a claim that every source was observed then.

`aiur build-orders --json` uses schema version 2. Its completion objects report `progress_resolution: "empty"` with `progress: null` when a Build Order has no members, distinguishing an observed empty plan from 0% progress.

Each source reports `state`, `observed_at`, `age_ms`, `freshness`, `partial`, and machine-readable `reasons`, while human output prints the same labelled state and age because a number without observation age is not actionable.

Fleet-capacity and build-gate evidence have independent source states: stale fleet
samples do not erase current build measurements; unavailable daemon process metrics
do not erase whole-host pressure; and missing values remain `null` in JSON and
`unavailable` in human output rather than becoming zero.

| Source condition | Output contract |
| --- | --- |
| Unavailable, stale, partial, invalid, or unknown observation time | Remains `null` or field-level status in JSON and a labelled warning in human output; it never becomes `0`, `[]`, or `{}` merely because the command could not measure it. |
| Observed empty source or valid zero-result filter | May return an empty collection. |
| Separately derived value, such as provider spend | Lives under `auxiliary` with its own source metadata. |

## Decisions, Executor events, and findings

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur ask "Title"` | Creates a durable operator request for the current repository. Add `--body` or `--body-file`, `--urgency low\|normal\|high`, and `--blocking` as needed. | `aiur ask "Approve production cutover" --blocking --urgency high` |
| `aiur ask "Title" --body "Context"` | Stores short supporting Markdown in the ask. | `aiur ask "Approve production cutover" --body "Production freeze ends today."` |
| `aiur ask "Title" --body-file request.md` | Reads the supporting body from a UTF-8 file. | `aiur ask "Approve production cutover" --body-file request.md` |
| `aiur ask "Title" --urgency high` | Classifies the request as `low`, `normal`, or `high`. | `aiur ask "Approve production cutover" --urgency high` |
| `aiur ask --done ASK-ID` | Resolves one open ask; `--note` records the resolution context. | `aiur ask --done ask_123 --note "Approved by release manager"` |
| `aiur ask --done ASK-ID --note "Approved"` | Saves the optional resolution context with a completed ask. | `aiur ask --done ask_123 --note "Approved by release manager"` |
| `aiur asks` | Lists open asks by default. Use `--all` to include resolved records and `--json` for the durable rows. | `aiur asks --all --json` |
| `aiur asks --open` | Makes the open-asks default explicit. | `aiur asks --open --json` |
| `aiur commands` | Lists durable Executor decisions. An optional decision ID selects one record. | `aiur commands` |
| `aiur commands --filter open` | Accepts `all`, `open`, `blocking`, or `resolved`. `--ticket` and `--search` require `--filter all`. | `aiur commands --filter open` |
| `aiur commands --blocking` | Limits the decision list to blocking records. | `aiur commands --blocking` |
| `aiur commands --ticket 142` | Narrows an `all` decision query to a ticket. | `aiur commands --filter all --ticket 142` |
| `aiur commands --search timeout` | Searches an `all` decision query. | `aiur commands --filter all --search timeout` |
| `aiur commands --cursor TOKEN` | Continues a paginated decision query. | `aiur commands --cursor TOKEN` |
| `aiur commands --limit 20` | Sets a positive result limit. | `aiur commands --limit 20` |
| `aiur commands --json` | Emits machine-readable decision rows. | `aiur commands --json` |
| `aiur executor-answer DECISION-ID` | Records a supervising-Executor answer to one open decision. It requires `--expected-version`, `--rationale`, `--idempotency-key`, and exactly one of `--option` or `--custom-response`. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --expected-version 1` | Optimistic-concurrency guard. It must be a positive integer and must match the decision's current version, so a stale answer is rejected instead of overwriting a newer one. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --option morning` | Selects one of the decision's offered option IDs. It is mutually exclusive with `--custom-response`. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --custom-response "Hold"` | Supplies a bounded free-text answer instead of an offered option. It is mutually exclusive with `--option`. | `aiur executor-answer dec_123 --expected-version 1 --custom-response "Hold until Monday" --rationale "Freeze" --idempotency-key run-2` |
| `aiur executor-answer DECISION-ID --rationale "Why"` | Required. It records why the answer was chosen, so decision history is auditable. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --idempotency-key run-1` | Required. Replaying the same key does not record a second answer, so a retried command is safe. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --executor-id exec-1` | Optional attribution for the answering Executor. It must not be empty when present. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1 --executor-id exec-1` |
| `aiur executor-escalate DECISION-ID` | Hands a decision back to the human Executor instead of answering it. It requires `--expected-version` and `--reason`. | `aiur executor-escalate dec_123 --expected-version 1 --reason "Needs the release owner"` |
| `aiur executor-escalate DECISION-ID --reason "Text"` | Required. It records why the supervising Executor declined to answer. | `aiur executor-escalate dec_123 --expected-version 1 --reason "Needs the release owner"` |
| `aiur executor-moot DECISION-ID` | Retires a Command whose question is void — its ticket closed or its originating agent is gone — recording why and by whom, without fabricating an answer. It requires `--expected-version` and `--reason-class`. | `aiur executor-moot dec_123 --expected-version 1 --reason-class ticket_closed` |
| `aiur executor-moot DECISION-ID --reason-class ticket_closed` | Required. A bounded class such as `ticket_closed` or `origin_agent_gone` that explains why the Command was voided. | `aiur executor-moot dec_123 --expected-version 1 --reason-class origin_agent_gone --reason "Agent no longer runs"` |
| `aiur executor-moot DECISION-ID --reason "Text"` | Optional free-text detail explaining why the Command was retired. | `aiur executor-moot dec_123 --expected-version 1 --reason-class ticket_closed --reason "Folded into #2073"` |
| `aiur executor-moot DECISION-ID --executor-id exec-1` | Optional attribution for the Executor retiring the Command. It must not be empty when present. | `aiur executor-moot dec_123 --expected-version 1 --reason-class ticket_closed --executor-id exec-1` |

A mooted Command leaves `aiur commands --blocking` and the open/blocking counts, stays visible under `--filter resolved`, and keeps its answer unset in the audit history.

Executor mutation failures include a remedy on stderr. Supply any named missing flag and retry; when `--expected-version` is stale, read the current version from the error and retry only after confirming the Command has not changed unexpectedly.

If `executor-answer` says a field is outside Executor scope, use `aiur executor-escalate` with the same decision ID and current version.

A stopped daemon is reported separately with the command needed to start it; a live but silent or unreachable daemon reports the attempted decision ID, expected version, and daemon endpoint so the same call can be diagnosed without guessing.

| `aiur executor-listen` | Persists the requested subscription, then streams all persisted-pattern events after the saved cursor before live events as JSON lines. It intentionally does not use the ten-second one-shot RPC timeout. | `aiur executor-listen` |
| `aiur executor-listen --topic 'executor.#'` | Adds that validated AMQP topic pattern before listening; the default is `executor.#`. Empty segments and malformed patterns are rejected. | `aiur executor-listen --topic 'executor.#'` |
| `aiur executor-wait` | Returns immediately when durable Executor wake records are pending; otherwise blocks for up to 300 seconds. Exit `0` means woken, `75` means quiet timeout. It auto-claims the wake stream when nobody holds it, and the shared cursor advances only for the owner. | `aiur executor-wait` |
| `aiur executor-wait --timeout 60 --json` | Sets the positive timeout in seconds and emits the identifier-only wake batch as JSON, alongside this consumer's `role`. Non-Executor wakes contain validated IDs and typed flags, never source free text. | `aiur executor-wait --timeout 60 --json` |
| `aiur executor-wait --as agent-b` | Names the consumer explicitly instead of using `AIUR_EXECUTOR_ID` or the derived host identity. Refused by a live owner, it reads the same records as an observer and does not advance the cursor. | `aiur executor-wait --as agent-b` |
| `aiur executor-roster` | Lists every Executor consumer with the evidence behind its state: role, host, pid, `claimed_at`, `last_renewed_at`, `last_acknowledged_at`, `pending_count`, cursor position, and whether the cursor moved since the previous observation. | `aiur executor-roster --json` |
| `aiur executor-claim` | Claims the wake stream. Refused when a live, renewing owner holds it; the refusal names that owner so a takeover is an operator decision, never a silent steal. | `aiur executor-claim --as agent-a` |
| `aiur executor-release` | Gives up this consumer's claim so a successor can take over immediately. | `aiur executor-release --as agent-a` |
| `aiur executor-revoke <consumer-id>` | Operator-only revoke of the named live owner. Requires the owner's id, read from the roster first. | `aiur executor-revoke agent-a` |
| `aiur executor-emit executor.note --payload '{"text":"ready"}'` | Publishes JSON on a nonempty `executor.` topic. Empty segments and other namespaces are rejected. | `aiur executor-emit executor.note --payload '{"text":"ready"}'` |
| `aiur executor-subscribe 'executor.#'` | Adds a persistent Executor event binding. Bindings accept `executor.*` and reviewed ticket/system patterns only; broader wildcards are rejected. | `aiur executor-subscribe 'executor.#'` |
| `aiur executor-unsubscribe 'executor.#'` | Removes that exact persistent binding. | `aiur executor-unsubscribe 'executor.#'` |
| `aiur executor-subscriptions` | Lists persistent Executor event bindings. | `aiur executor-subscriptions` |
| `aiur findings` | Reads the host-local findings ledger. | `aiur findings` |
| `aiur findings --unfiled` | Filters ledger entries that have no filed ticket. | `aiur findings --unfiled` |
| `aiur findings --slugs` | Emits only finding slugs. | `aiur findings --slugs` |
| `aiur findings --scope repo` | Filters to `aiur` or `repo` scope. | `aiur findings --scope repo` |
| `aiur findings --record JSON --repo owner/repo` | Appends one validated finding to the named repository ledger. Both options are required together. | `aiur findings --record '{"slug":"example"}' --repo aiur-team/aiur` |
| `aiur findings --digest` | Generates the Markdown projection, optionally scoped. | `aiur findings --digest --scope repo` |

### Wake ledger bound and lease TTL

The wake ledger is capped at 10,000 records. Consumed records are evicted first.

Past the cap the **oldest unread wakes are evicted too**. The shared cursor is
advanced past them and an `executor.wakes.overflow` alert names the count and id
range; those wakes are never delivered.

In practice that only happens when a run records for a long time with no
consumer, or with a stalled one. The roster's `stalled` state is the earlier
warning.

A claim is a lease with a 10-minute TTL, renewed while `executor-wait` blocks and
on every claim, acknowledgement, or roster touch. A consumer that stops renewing
is reported `expired` after the TTL lapses, and a successor may take over with no
operator action.

### Executor roster states

A stalled consumer still holds a claim and still renews its lease, so a
presence-based list reports it as fine.

`aiur executor-roster` derives state from evidence, never from presence.

| State | Meaning |
| --- | --- |
| `active` | Positive evidence of consumption: it acknowledged inside the stall window, or the shared cursor moved since the previous observation. |
| `idle` | Lease live, nothing pending, cursor legitimately still. |
| `stalled` | Lease renewing, but acknowledgements are frozen while `pending_count` grows. The "backgrounded stuck" case. |
| `expired` | Lease lapsed. A successor may take over with no operator action. |
| `unknown` | The evidence needed to decide is missing. Never reported as `active`. |

Multiple executors are a supported configuration, so a healthy peer is listed
plainly and is not a fault. An agent reports what it finds and recommends; it
never revokes a live peer's claim on its own.

Records — the journal, wake inbox, cursor, and subscriptions — are created
automatically on first use beneath the per-repository state node
(`~/.aiur/repo/<owner>/<repo>/executor`), so they survive a daemon restart and a
successor resumes from the durable cursor.

`AIUR_EXECUTOR_ID` names this consumer when `--as` is omitted. Nothing infers
consumer identity from the terminal, parent process, or any other environment
signal.

Executor subscriptions are the Executor's half of the event system; see [Message Bus](/concepts/message-bus). Agents do not need these commands: every agent is auto-subscribed to its own comment, review, and CI topics, and to both directions of every blocker edge.

Normal control commands use a bounded RPC. After ten seconds the launcher terminates its helper and descendants, exits 124, and reports the timeout. A crash marker distinguishes a known crashed daemon from a stopped one; run `aiur stop` to reap possible orphaned agents before restarting.

An open **blocking** ask is also printed by plain `aiur status`; no extra flag is required. That keeps a durable request in the normal operating view instead of hiding it in a ledger that nobody reads.

`--blocking` and `--filter blocking` mean *dispatch is held until you answer this*, which is also what the dispatch gate reads.

An agent attention is a visibility signal rather than a gate — the agent keeps running after it opens one — so attentions are listed by `aiur commands` but are not counted as blocking.

Answering a Command also dismisses every other unanswered Command — open or deferred — asking the same question on the same ticket, so a question filed more than once clears in one answer. A blocking Command an agent is genuinely waiting on is never swept up this way, because dismissing it would deliver nothing to that agent.

Dismissing a Command closes it and moves it to history. If the Command's agent is still live, it is told to use its judgement and proceed; an agent that is gone is not notified.

## Operational facts that change an incident response

| Fact | Response |
| --- | --- |
| **Dispatch needs `agent:todo`.** | `AGENTS 0/32 (binding: ticket supply)` means a recent poll found no queued ticket. If it instead reads `has not polled yet (POLL backed off...)`, the daemon has not looked recently — run `aiur --todo <id>`, add the label, or trigger a refresh so the work is seen. |
| **Global pause is durable.** | Use `aiur status` and `aiur resume` before treating a silent restarted fleet as broken. |
| **CI readiness uses an operator-only token.** | Put `AIUR_CI_READINESS_TOKEN` with GitHub `workflow` scope in the daemon environment, restart, and never expose it to agent workspaces. |
| **A base refresh affects approval ownership.** | With `require_last_push_approval`, route a base refresh through the ticket agent so the Executor does not become the ineligible last pusher. |

## `aiurdev`, for developing Aiur itself

`scripts/aiurdev` is **only** for working on Aiur's own source. It builds and runs a local development release from a checkout, entirely separate from the `aiur` you installed with npm, bun, or Homebrew. If you are using Aiur rather than changing it, you never need this section.

Apart from the commands below, `aiurdev` executes the same launcher engine as `aiur`; it is one CLI surface, not two products.

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `scripts/aiurdev build` | Rebuilds the local release before the next run. The installed `aiur` does not have this command. | `scripts/aiurdev build` |
| `scripts/aiurdev build --deps` | Rebuilds dependencies as part of the development build. | `scripts/aiurdev build --deps` |
| `scripts/aiurdev --test` | Resets the single sandbox ticket, first stopping the keyed live daemon, then starts the foreground smoke harness. It is blocked from agent workspaces. | `scripts/aiurdev --test --force` |
| `scripts/aiurdev --test3` | Resets the three-ticket blocker-chain harness, stops the keyed live daemon first, and permits the remote scenario. It is blocked from agent workspaces. | `scripts/aiurdev --test3` |
| `scripts/aiurdev --clear` | Requires debug mode and deletes every entry under `~/.aiur/logs/` before the smoke run, not merely debug logs. | `scripts/aiurdev --debug --clear` |
| `scripts/aiurdev --allow-remote` | Permits the remote test scenario. | `scripts/aiurdev --test3 --allow-remote` |

`aiurdev` refuses every invocation from an existing tmux session because Aiur starts its own tmux socket. It pins the opencode binary selected by the release and preserves a complete existing release for control commands, so a control command does not rebuild a daemon it is about to contact.

### Which checkout `aiurdev` targets

`aiurdev` resolves its target repository from its own path, following symlinks first, so a globally symlinked `aiurdev` works from any directory. Set `AIUR_REPO_ROOT` to name a target explicitly and that choice always wins.

When the script path and current directory point at different checkouts, command intent decides the outcome.

| Command type | Outcome |
| --- | --- |
| `build`, `restart`, or bare run | Refuses with exit code 64 and prints both roots plus the two ways to resolve the mismatch. |
| Control or RPC command, including `status`, `stop`, `watch`, `units`, and `executor-answer` | Runs against the script's checkout, names that checkout, and reuses its release without rebuilding. |

| `AIUR_BUILD_STAMP` field | Why it matters |
| --- | --- |
| Repository root and source commit | A commit mismatch marks the release stale after operations such as `git switch`. |
| Dirty-tree flag and build time | Records the exact development build provenance. |

`aiur` accepts a path to a workflow configuration as the final run argument. Every fresh `aiur` or `aiurdev` launch prints `Config: /absolute/path` after startup, naming the configuration selected by discovery or that explicit argument. An already-running background no-op does not load or print a configuration.

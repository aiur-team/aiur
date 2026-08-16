---
pageClass: cli-reference
---

# CLI

`aiur` exists so an **agent can run Aiur on your behalf**. Aiur is normally driven by an Executor, and that Executor is usually an agent rather than a person typing commands, so the CLI deliberately targets feature parity with the [Dashboard](/guide/executor-control-center) and the [TUI](/guide/tui). Every capability those surfaces expose has a command here, so an agent operating over a terminal alone is never a second-class Executor.

A human can of course type any of it. Most humans will not: they watch the TUI or the dashboard and let their Executor agent drive.

Run the command from the repository that owns the run. An instance is keyed to that project, so control commands address that repository's daemon.

## What the CLI does

| Job | Commands | Notes |
| --- | --- | --- |
| Start a run | `aiur`, `aiur run` | Foreground gives the TUI board and chat panes; background is headless. |
| Inspect live state | `status`, `agents`, `watch`, `alerts`, `usage` | Read-only reports from the running daemon. |
| Operate the fleet | `set max-agents`, `pause`, `resume`, `message`, `reset-budget`, `stop`, `restart` | Steers a live run. |
| Mirror a dashboard page | `units`, `commands`, `build-orders`, `analytics` | Read-only terminal forms of the dashboard pages. |
| Act on durable records | `ask`, `asks`, `executor-answer`, `executor-escalate`, `executor-emit`, `executor-listen`, `findings` | Decision inbox, Executor events, and findings ledger. |
| Guard a repository | `guard-pr-deletions` | Refuses a PR with excessive untouched deletions. |

Background mode is the shape that matters for an agent Executor. `aiur --bg` starts the daemon with no board and no panes, the dashboard stays up, and every command below reads and writes the same live state through that detached daemon.

## Start, initialize, and queue

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur` | Starts a foreground interactive run. The launcher supplies a lower-precedence Tailscale-or-loopback host default, interactive UI, and required guardrail acknowledgement when absent. | `aiur` |
| `aiur run` | Explicit foreground launch form. `--bg` makes it headless; `--interactive` restores terminal panes in a background session. | `aiur run --bg` |
| `aiur init` | Interactive setup detects the tracker and toolchain, writes `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`, `.aiur/alerts`, and prewarm support when selected, then creates the repository state-node tree and warms the base build. It also asks whether to enable Stream Deck voice input with ElevenLabs speech-to-text; answering yes writes the `elevenlabs` section, defaulting the key to the `$ELEVENLABS_API_KEY` environment reference. A resumed `aiur init` offers the same question when the saved config predates the section. | `aiur init` |
| `aiur init --force` | Recreates generated configuration. Re-running without it preserves existing scaffold files. | `aiur init --force` |
| `aiur --todo 142 143` | Requires a running daemon and one or more numeric IDs, with commas also accepted. A stopped daemon exits nonzero. | `aiur --todo 142,143` |
| `aiur --todo 142 --only` | Queues the named IDs and asks GitHub to remove `agent:todo` from other pending tickets. It is GitHub-only, is bounded to 50 cleanup targets, and stops after three consecutive rate-limit failures. Cleanup is skipped if a requested ID fails, so the operation does not silently dequeue work after a bad request. | `aiur --todo 142 --only` |
| `aiur --bg` | Starts detached headless execution. It has no agent-list or chat panes; use the dashboard or control commands. | `aiur --bg` |
| `aiur --debug` | Enables debug logs and durable chat-pane recording for this run. | `aiur --debug` |
| `aiur --pause` | Cold-starts with the global provisioning switch paused. | `aiur --pause` |
| `aiur --max-agents 6` | Launch-only session cap. It wins over `agent.max_concurrent_agents`; Aiur warns when it exceeds that setting. `status` identifies the active binding. | `aiur --max-agents 6` |
| `aiur --interactive` | Requests the terminal UI, including from a background launch. | `aiur --bg --interactive` |
| `aiur --headless` | Requests no terminal UI. Background launch injects it unless `--interactive` is present. | `aiur run --headless` |
| `aiur --no-dashboard` | Suppresses the dashboard listener in foreground or background mode. It is rejected for Remote Control because its lifecycle hooks need the listener. | `aiur --bg --no-dashboard` |
| `aiur --host 127.0.0.1` | Overrides the dashboard bind host. A non-loopback host requires dashboard credentials. | `aiur --host 127.0.0.1` |
| `aiur --port 4000` | Overrides the HTTP port. `0` lets the OS choose a free port. | `aiur --port 4000` |
| `aiur --logs-root /var/log/aiur` | Overrides the daemon log root for this launch. | `aiur --logs-root /var/log/aiur` |
| `aiur --i-understand-that-this-will-be-running-without-the-usual-guardrails` | Required by the release parser; the launcher inserts it for normal run commands. | `aiur run --i-understand-that-this-will-be-running-without-the-usual-guardrails` |
| `aiur --version` | Prints the release version without contacting or claiming a running daemon. | `aiur --version` |

Foreground mode has the terminal board and chat panes. `--bg` is headless but still starts the dashboard unless `--no-dashboard` is passed. A configured `server.host` wins over the launcher's default; `--host` wins over both. The default is loopback, or an authenticated Tailscale address when one is safely available. Startup output reports both the usable dashboard URL and its effective bind host and port.

## Inspect and operate a running daemon

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur help` | Prints the current launcher usage. | `aiur help` |
| `aiur status` | Shows daemon and capacity status, including `AGENTS occupied/max (binding: ...)`. The binding is `config max_concurrent_agents`, `AIMD envelope`, `paused reservations`, `ticket supply`, `session max_concurrent_agents`, or `none`. `ticket supply` means no queued ticket is available, not that the configured cap is zero. | `aiur status` |
| `aiur usage` | Prints the current provider-meter observations and their known headroom. | `aiur usage` |
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
| `aiur set max-agents 6` | Changes the live session cap without editing config. It takes effect immediately and does not rewrite the next launch's config. | `aiur set max-agents 6` |
| `aiur pause` | Turns on the global pause switch. It stops new provisioning and cooperatively holds the fleet. The switch is persisted with its source and survives restart; a failed persisted-state read starts paused. | `aiur pause` |
| `aiur resume` | Turns off that global switch. | `aiur resume` |
| `aiur pause 142 143` | Requests a safe-boundary pause for named tickets. | `aiur pause 142,143` |
| `aiur pause --all` | Requests a pause for every active ticket. | `aiur pause --all` |
| `aiur resume 142` | Resumes a paused ticket, or starts an idle eligible ticket. | `aiur resume 142` |
| `aiur resume --all` | Resumes every individually paused ticket. | `aiur resume --all` |
| `aiur reset-budget 142` | Clears a named ticket's dispatch-budget latch. It does not accept `--all`; `resume` cannot clear this latch. | `aiur reset-budget 142` |
| `aiur message 142 "Check review"` | Delivers Executor text through the native agent queue. Aiur may interrupt at a safe point, queue it for the next turn, auto-resume a paused entry, or reactivate a deactivated entry. Text must be nonblank and at most 8,000 characters. | `aiur message 142 "Check the latest review"` |
| `aiur stop` | Stops the BEAM and its tmux lifetime session. A stopped daemon makes `stop` and `--todo` exit nonzero. | `aiur stop` |
| `aiur restart` | Stops the running session, refreshes the release, and starts it again detached. See [Restart semantics](#restart-semantics). | `aiur restart` |
| `aiur restart --no-build` | Bounces the daemon on whatever release is already on disk. Use it for a fast restart, or to bounce without taking uncommitted source edits live. It has no effect on the installed `aiur`, which never builds. It cannot rescue a failed development rebuild: that removes the incomplete release, so there is nothing left to start, and `restart` says so instead of suggesting it. | `aiur restart --no-build` |
| `aiur cleanup-stale` | Lists and reaps stale manual-smoke processes and sockets. | `aiur cleanup-stale` |
| `aiur cleanup-stale --dry-run` | Reports stale leftovers without reaping them. | `aiur cleanup-stale --dry-run` |
| `aiur guard-pr-deletions main` | Refuses a PR that deletes more than 50 files the branch never touched. Reads the base branch from the argument or `AIUR_BASE_BRANCH`, and the branch start from `AIUR_BRANCH_START_SHA` or `refs/aiur/branch-start`. Exit 1 is a refusal, exit 2 is an unusable input such as a dirty tree, an unfetchable base, or a missing branch-start ref. | `aiur guard-pr-deletions main` |

### Restart semantics

The refresh runs between the stop and the start, so the new daemon boots on current code. The installed `aiur` runs a pinned release and has nothing to build, so its restart is a plain bounce. A daemon that was already stopped is simply started. A daemon still answering after the stop aborts the restart rather than being rebuilt underneath. `restart` bounces the instance its stop resolved.

Any failure after the stop, whether a failed rebuild, a failed start, or an interrupt, reports that the daemon is stopped and was not restarted.

Under `scripts/aiurdev` the refresh must prove itself. The rebuild reports the release directory and source commit it produced, and `restart` checks both against the release it is about to boot. A rebuild it cannot confirm aborts the start with exit code 70 and names the builder it could not confirm, rather than reporting a successful restart. A build command that does not declare it reports a receipt is not held to that contract: the restart proceeds and says plainly that it is unverified.

## Dashboard page commands

`aiur units`, `aiur commands`, `aiur build-orders`, and `aiur analytics` are read-only terminal forms of the corresponding Dashboard pages. They read the page's projection or provider rather than independently polling GitHub or treating `/api/v1/state` as the source of truth.

| Command | Page view and important inputs | Example |
| --- | --- | --- |
| `aiur units` | Filtered Units catalog; use `--scope`, repeated `--condition`, `--format`, or `--json`. | `aiur units --scope unfinished --condition alert --json` |
| `aiur commands [decision-id]` | Durable decision inbox, or one selected decision. Use `--filter all\|open\|blocking\|resolved`, `--blocking`, `--ticket`, `--search`, `--cursor`, `--limit`, and `--json`. `--ticket` and `--search` require `--filter all`. | `aiur commands --filter blocking --json` |
| `aiur build-orders [root]` | Build Order catalog without a root; one root adds graph, execution, and activity detail. | `aiur build-orders 1567 --json` |
| `aiur analytics` | Analytics snapshot. Choose `--range run\|full`, an ISO-8601 `--since`/`--until` window, an optional numeric `--build-order`, or `--json`. | `aiur analytics --range full --build-order 1567 --json` |
| `aiur analytics --range full` | Selects the current run or all retained analytics observations. | `aiur analytics --range full` |
| `aiur analytics --since 2026-08-01T00:00:00Z` | Sets the inclusive ISO-8601 start of an analytics window. | `aiur analytics --since 2026-08-01T00:00:00Z` |
| `aiur analytics --until 2026-08-02T00:00:00Z` | Sets the exclusive ISO-8601 end of an analytics window. | `aiur analytics --until 2026-08-02T00:00:00Z` |
| `aiur analytics --build-order 1567` | Limits analytics to one numeric Build Order root. | `aiur analytics --build-order 1567` |

### Output contract

Every `--json` result is one versioned envelope with `schema_version`, `page`, `snapshot.captured_at`, `request`, `sources`, `data`, and `auxiliary`. `snapshot.captured_at` is when the command ran; it is not a claim that every source was observed then.

Each independently-read source reports its `state`, `observed_at`, `age_ms`, `freshness`, `partial`, and machine-readable `reasons`. Human output starts with that capture time and prints the same labelled source state and age before its values. This is intentional: a number without an observation age is not actionable.

Known absence stays explicit. A source that is unavailable, stale, partial, invalid, or has an unknown observation time remains a `null` or a field-level status in JSON and a labelled warning in human output; it never becomes `0`, `[]`, or `{}` merely because the command could not measure it. An empty collection means an observed empty source or a documented, valid zero-result filter, never an outage. `auxiliary` holds separately-derived values such as provider spend and preserves their own source metadata instead of merging an estimate into the page's primary data.

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
| `aiur executor-listen` | Persists the requested subscription, then streams all persisted-pattern events after the saved cursor before live events as JSON lines. It intentionally does not use the ten-second one-shot RPC timeout. | `aiur executor-listen` |
| `aiur executor-listen --topic 'executor.#'` | Adds that validated AMQP topic pattern before listening; the default is `executor.#`. Empty segments and malformed patterns are rejected. | `aiur executor-listen --topic 'executor.#'` |
| `aiur executor-emit executor.note --payload '{"text":"ready"}'` | Publishes JSON on a nonempty `executor.` topic. Empty segments and other namespaces are rejected. | `aiur executor-emit executor.note --payload '{"text":"ready"}'` |
| `aiur executor-subscribe 'executor.#'` | Adds a persistent Executor event binding. | `aiur executor-subscribe 'executor.#'` |
| `aiur executor-unsubscribe 'executor.#'` | Removes that exact persistent binding. | `aiur executor-unsubscribe 'executor.#'` |
| `aiur executor-subscriptions` | Lists persistent Executor event bindings. | `aiur executor-subscriptions` |
| `aiur findings` | Reads the host-local findings ledger. | `aiur findings` |
| `aiur findings --unfiled` | Filters ledger entries that have no filed ticket. | `aiur findings --unfiled` |
| `aiur findings --slugs` | Emits only finding slugs. | `aiur findings --slugs` |
| `aiur findings --scope repo` | Filters to `aiur` or `repo` scope. | `aiur findings --scope repo` |
| `aiur findings --record JSON --repo owner/repo` | Appends one validated finding to the named repository ledger. Both options are required together. | `aiur findings --record '{"slug":"example"}' --repo aiur-team/aiur` |
| `aiur findings --digest` | Generates the Markdown projection, optionally scoped. | `aiur findings --digest --scope repo` |

Executor subscriptions are the Executor's half of the event system; see [Coordination and events](/concepts/coordination). Agents do not need these commands: every agent is auto-subscribed to its own comment, review, and CI topics, and to both directions of every blocker edge.

Normal control commands use a bounded RPC. After ten seconds the launcher terminates its helper and descendants, exits 124, and reports the timeout. A crash marker distinguishes a known crashed daemon from a stopped one; run `aiur stop` to reap possible orphaned agents before restarting.

An open **blocking** ask is also printed by plain `aiur status`; no extra flag is required. That keeps a durable request in the normal operating view instead of hiding it in a ledger that nobody reads.

## Operational facts that change an incident response

- **Dispatch needs `agent:todo`.** An issue can be open, labelled, eligible, and unblocked yet still not dispatch until it carries `agent:todo`. If `aiur status` says `AGENTS 0/32 (binding: ticket supply)`, it means no queued ticket is available, not that no work exists. Queue it with `aiur --todo <id>` or add the label.
- **Global pause is durable.** Bare `aiur pause` is a fleet-wide provisioning switch and survives restart. A restarted fleet can therefore be correctly silent; use `aiur status` and `aiur resume` rather than assuming the daemon lost work.
- **CI readiness uses an operator-only token.** Set `AIUR_CI_READINESS_TOKEN` in the daemon's environment with GitHub `workflow` scope, then restart the daemon. The daemon reads it for workflow inspection and removes it from every agent shell; do not put it in an agent workspace or prompt.
- **A base refresh affects approval ownership.** With `require_last_push_approval`, an Executor who refreshes a stale PR branch becomes its last pusher and cannot satisfy the required approval. Route the fetch, merge, and push through that ticket's agent identity instead; then obtain or retain review under the repository's normal rules.

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

When the target is derived from the script path and the current directory sits inside a *different* Aiur checkout, the outcome depends on what the command is for:

- Commands whose purpose is to produce or boot a release, meaning `build`, `restart`, and a bare run, **refuse** with exit code 64 and print both roots plus the two commands that resolve it. Otherwise a build reports success against a checkout you are not working in, and a subsequent `restart` boots that release.
- Every other command, including `status`, `stop`, `watch`, `units`, and `executor-answer`, still runs, because it only needs to reach the daemon and refusing would leave a blocked agent unanswerable. It prints which checkout it is speaking through and reuses that checkout's existing release rather than rebuilding it, so answering an RPC never rewrites a release some other daemon is booted from.

Every completed development build writes `AIUR_BUILD_STAMP` into the release directory, recording the repository root, the source commit, whether the tree was dirty, and the build time. A release stamped with a commit other than the one checked out is treated as stale and rebuilt, even when no source file is newer than it. That is exactly the case a `git switch` leaves behind.

`aiur` accepts a path to a workflow configuration as the final run argument.

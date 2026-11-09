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
| `aiur --categories a,b` | Limits a new client token to the named control-call categories. | `aiur token create hub --categories read,message` |
| `aiur --debug` | Enables debug logs and durable chat-pane recording for this run. Analytics capture does not depend on `--debug`. | `aiur --debug` |
| `aiur --digest` | Prints the compact digest for the current run. | `aiur --digest` |
| `aiur --dir PATH` | Selects a working directory for a supported command. | `aiur --dir ./project` |
| `aiur --done TEXT` | Adds completion text to a supported command. | `aiur --done 'Merged'` |
| `aiur --executor` | Marks the run as Executor-owned and registers its renewing principal in `executor-roster`. Recording is **not** gated on this flag: every run arms the supervised `executor.#` listener and the wake inbox, so PR-lifecycle, CI and attention records exist for a later agent to replay. What the flag adds is authority — created and deferred Commands are raised as needs-attention alerts only on an Executor-owned run. On startup it also records an informational, retrospective daemon heartbeat gap when the durable lifecycle journal confirms a clean stop or an unclosed prior start. This is not live monitoring: no alert is emitted while Aiur is stopped; the notice appears on the next Executor startup. `LISTENER absent` is therefore always a fault. | `aiur --bg --executor` |
| `aiur --gateway NAME` | Must be the first argument. Selects a registry gateway by name, label or `gateway_id` like `--instance`, or `all` or `local`; see [Selecting by `--gateway`](#selecting-by-gateway). | `aiur --gateway nook status` |
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
| `aiur --peer ID` | Binds a new client token to a gateway id; categories default to `read`. | `aiur token create hub --peer gw-hub` |
| `aiur --port 4000` | Overrides the HTTP port. `0` lets the OS choose a free port. | `aiur --port 4000` |
| `aiur --project OWNER/REPO` | Targets one project on a multi-project gateway; see [Choosing a project](#choosing-a-project). | `aiur --gateway nook queue show --project o/b` |
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
| `aiur command` | Lists open Commands; use the same command with an ID for detail or an answer. `commands` remains a compatibility alias. | `aiur command` |
| `aiur command --filter open` | Applies the existing Command filters through the canonical singular command. | `aiur command --filter open` |
| `aiur command DECISION-ID` | Shows question, options, recommendation, context, status and delivery. | `aiur command dec_123` |
| `aiur command DECISION-ID --custom-response TEXT` | Records a local operator's bounded text answer after interactive confirmation. | `aiur command dec_123 --custom-response 'Wait for a fresh build'` |
| `aiur command DECISION-ID --option ID` | Records a local operator answer after preview and exact-ID confirmation in an interactive terminal. | `aiur command dec_123 --option keep` |
| `aiur command DECISION-ID --option ID --relayed --quote TEXT [--idempotency-key KEY]` | Relays an operator's already-given answer with the current version and a generated idempotency key unless one is supplied. Reuse a supplied key to safely retry after an unknown outcome; requires the relay config gate. | `aiur command dec_123 --option keep --relayed --quote 'Keep them' --idempotency-key relay-1` |
| `aiur command request <question>` | Creates an Executor-originated Command for the human; requires a running daemon. | `aiur command request 'Ship today?' --option yes=Ship --option no=Wait` |
| `aiur command request <question> --context-file PATH` | Reads up to 20,000 characters of local Markdown context before RPC; omitted by default. | `aiur command request 'Ship?' --context-file release.md` |
| `aiur command request <question> --media FILE-OR-URL[,kind=K,alt=TEXT,caption=TEXT,option=ID]` | Attaches typed media to the prompt, or to one option with `option=ID`; repeatable. Local files must sit under a configured root and become attachments; HTTPS URLs must be allowlisted; expiring URLs are refused. MIME type and kind are inferred from the extension unless `mime=` or `kind=` is given. | `aiur command request 'Which sprite?' --option a=Left --option b=Right --media shots/a.png,option=a,alt='Left sprite'` |
| `aiur command request <question> --recommend ID` | Moves the named supplied option first; omitted by default. | `aiur command request 'Ship?' --option yes=Ship --option no=Wait --recommend yes` |
| `aiur command request <question> --short-summary TEXT` | Adds a concise Command title; omitted by default. | `aiur command request 'Ship?' --short-summary 'Beta release'` |
| `aiur executor-attach --check [--json]` | Diagnose Executor attachment without changing it; exit 1 for fail or unknown. | `aiur executor-attach --check --json` |
| `aiur executor-attach --harness claude` | Required: explicitly select claude or codex. | `aiur executor-attach --harness claude` |
| `aiur executor-attach --harness claude --print-config` | Prints hooks instead of installing them; Codex always prints. | `aiur executor-attach --harness claude --print-config` |
| `aiur executor-attach --harness claude --takeover` | Replaces a live binding; off by default. | `aiur executor-attach --harness claude --takeover` |
| `aiur init --force` | Recreates generated configuration for the location you choose at the first prompt; picking repo-local leaves an existing `~/.aiur/config` untouched. `--force` explicitly re-runs setup choices, including recorded declines. Re-running without it preserves existing scaffold files and recorded declines. | `aiur init --force` |
| `aiur operator-relay-answer ID --quote TEXT --relayed-by EXECUTOR` | Both flags are required: preserve verbatim operator words and the recording Executor identity. Requires the relay config gate, version, choice and idempotency key. | `aiur operator-relay-answer dec_123 --expected-version 1 --option keep --quote 'keep them' --relayed-by attended-executor --idempotency-key palette-1` |
| `aiur redispatch 142 --backend codex` | Selects a backend for a ticket redispatch. | `aiur redispatch 142 --backend codex` |

## Remote instances

`--instance <name>` selects a daemon from `~/.aiur/remote-instances.yaml` and must lead the arguments (optionally followed by `--request-id`). Commands without it keep using the local daemon. Each registry entry has a URL and exactly one token reference:

```yaml
version: 1
instances:
  nuc:
    url: https://nuc.example.ts.net
    token_env: AIUR_TOKEN_NUC
```

Use an `AIUR_TOKEN_*` environment variable for write tokens. A `token_file` is intended for read tokens, must be absolute or start with `~/` (resolved beneath the current user's home directory), and must have mode `0600`. Remote URLs require HTTPS; plain HTTP is accepted only for `127.0.0.0/8`, `::1`, and `localhost`.

The client refuses commands that need local files, processes, or terminal streaming before it makes an HTTP request:

- Local lifecycle and maintenance: bare `aiur`, `run`, `--bg`, `stop`, `restart`, `aiurdev build`, `cleanup-stale`, `doctor`, `upgrade`, and `pre-pr`.
- Streaming, setup, and client-only commands: `listen`, `executor-listen`, `init`, `login`, `logout`, `pr`, `findings`, `ask`, `asks`, `answer`, `history export`, help, and `--version`.

`redispatch`, `ticket estimate`, `ticket owner`, `ticket assign`, `operator-relay-answer`, and `history label-writes` work with `--instance`.

Remote `executor-wait`, `executor-claim`, `executor-release`, and `executor-fast-forward` require `--as <id>`.

### Selecting by `--gateway`

`--gateway <name|label|id|all|local>` behaves like `--instance`. It must be the first argument and cannot be combined with `--instance` (exit 64).

- A registry name matches exactly. A `label` or a full `gateway_id` matches case-insensitively; id prefixes do not match.
- No match, or more than one, exits 64. An ambiguous selector lists every match; use `--instance <name>` to pick one.
- `all` is the read-only fan-out, as with `--instance all`.
- `local` always means this machine: no registry read, no HTTP. An entry literally named `local` is reached with `--instance local`.
- `stop` and `restart` exit 64 with `stop is local to the gateway's host; run it there`.
- `aiurdev` accepts the same flag.

### Pinning a gateway identity

An entry may also carry `gateway_id` (26 lowercase base32 characters), `label` (display only), `tls_pin_sha256` and an `allows:` block (read by the inbound receiver; the CLI and Stream Deck skip it). Older launchers reject registries that use these keys.

An entry with no `url` or token that carries `allows` or `gateway_id` is inbound-only: `--instance <name>` exits 64 and `--instance all` skips it.

`tls_pin_sha256` is the lowercase hex SHA-256 of the server's public key (SPKI). The CLI then trusts that key alone, which allows a self-signed certificate; the Stream Deck sidecar does not enforce it. Derive it with `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | xxd -p -c 64`.

The first successful call to an unpinned entry prints, on stderr, the id the gateway answered with and the line to add under the entry. The id is remembered in `~/.aiur/remote-state/seen-gateway/<name>`; the registry is never written for you.

With `gateway_id` set, a 200 response with a different id exits 77 with `gateway identity mismatch for '<name>'` and prints no command output. A pinned entry also refuses a response with no `gateway_id`, so pin only against a gateway build that reports one.

The check runs after the request is sent: the bearer token has already reached that host, and a write may have run there.

### Remote environment

| Environment variable | Behavior |
| --- | --- |
| `AIUR_REMOTE_MAX_SCOPE` | Sets the `max_scope` sent with a remote control request. Defaults to `write`. |
| `AIUR_REQUEST_ID` | A UUIDv7 sent as the `request_id` of a remote write, same as `--request-id`. Unset, the client generates one per write. |
| `AIUR_JS_RUNTIME` | Selects the JavaScript runtime used to encode requests and decode responses. The npm launcher sets it to its current runtime; `aiurdev` defaults to `node` from `PATH`. |

Remote `status` skips the local mise-doctor check. Tables use the daemon's default width because the remote capture has no terminal.

A remote timeout is never retried automatically. For writes, `outcome unknown on <name>` means the answer was lost, not that the write failed.

### Replay-safe writes

Every remote write carries a UUIDv7 `request_id`, and the daemon runs each `(token, request_id)` once for 24 hours.

| Result | Exit | Meaning |
| --- | --- | --- |
| Timeout or lost connection | 124 | Prints `retry with --request-id <id> is safe`. A retry returns the stored result; it never runs the write again. |
| `request_in_progress` (HTTP 409) | 75 | The first request is still running; retry later with the same id. |
| `outcome_unknown` (HTTP 409) | 124 | The daemon restarted mid-call. The write is never re-run; check state, then use a new id. |
| `request_id_reused` (HTTP 422) | 64 | The id was already used with a different command. |

The client generates the id (control contract version 2); `--request-id <id>` or `AIUR_REQUEST_ID` supplies your own. It cannot be combined with `--instance all`.

A contract version 1 daemon ignores `request_id`. Audit lines carry `request_id`, `origin_gateway` and `actor`; a repeat is audited as `replayed`.

### Choosing a project

A gateway can serve several projects (repositories). `--project <owner/repo>` names the one a command works on. It is accepted right after the selector (`aiur --gateway nook --project o/b queue show`) or after the command name (`aiur --gateway nook queue show --project o/b`).

| Command | Takes `--project` |
| --- | --- |
| `queue`, `lane`, `epic`, `feature`, `units`, `build-orders`, `analytics`, `set` (not `set --list` or `set max-agents`) | Yes |
| `status`, `agents`, `alerts` and every other command | No: exit 64 `--project does not apply` |

When `--project` is omitted:

- **Local**: the project is the repository of the current directory when this gateway runs it; otherwise the gateway's only project.
- **Remote**: the gateway's only project.
- **Several projects and no match**: exit 64 `pick a project: o/a, o/b`; nothing runs.

A single-project gateway ignores a matching `--project` and refuses another one (exit 64 `unknown project 'o/z'; this gateway has: o/a`). `--project` cannot be combined with `--instance all` or `--gateway all`, and must look like `owner/repo`.

`aiur set` and `aiur set --unset` over a gateway send `project` instead of the caller's working directory. Ticket-id commands (`take`, `message`, `--todo`, ...) do not take `--project` yet.

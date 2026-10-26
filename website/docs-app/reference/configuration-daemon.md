# Daemon configuration

Configuration lives in `.aiur/config` (YAML), and `prompt_file:` and `hooks_file:` point at sibling files.

With no local config, Aiur uses `~/.aiur/config` without per-repository init.

Global GitHub startup announces its current-origin target and ensures workflow/marker and complexity labels, without creating model labels.

Omit `tracker.github.repo` for portable defaults; a conflicting explicit repo fails safely.

Shared credentials can live in `~/.aiur/.env` using the precedence below.

Older root-level config files are rejected.

When moving one, also move the files it references, or rewrite their paths so they still resolve from the new config directory.

Supported secret and workspace-root fields resolve `~` and `$VAR` values; other path fields do not generally expand environment references.

Runtime overrides set with `aiur set` are operator-owned and stored per instance without changing this YAML. The daemon cooperatively refuses mutations when raw caller path evidence matches its configured or live agent workspaces; #6075 tracks authenticated operator-token enforcement.

Live keys: `agent.max_concurrent_builds`, `agent.max_concurrent_agents_by_state`, `agent.priority`, `agent.routing`, `build_queue.max_active_sets`, `instance.ignore.tickets`, `instance.owns`, `instance.pool`.

Precedence: session `set max-agents` (agent cap), runtime overrides, YAML, defaults. `aiur set --list` shows provenance; `aiur set --unset <key>` restores YAML.

## Environment variables
Environment variables are declared once in the env schema (`Aiur.Env.Schema`), which validates them at startup and generates the checked-in `.env.example` (run `mix aiur.env.example` from `src/` to regenerate; a CI check fails when the example drifts from the schema).
- **Layering.** Shell exports win, then `./.env`, then `~/.aiur/.env`: the launcher reads the repository file first and each file fills only unset names, so the home file only fills the gaps. A blank value such as the `GITHUB_TOKEN=` placeholder `aiur init` writes is not a setting and shadows nothing. GitHub credentials (`GITHUB_TOKEN` and the `GITHUB_APP_*` set) resolve as one group: when `./.env` sets any of them, every GitHub credential in `~/.aiur/.env` is ignored, so a machine-wide App never outranks the token a repository configured for itself. When the home value loses either way, the daemon logs a startup warning naming the variable (never its value).
- **Hosted environment-only mode.** Set `AIUR_SECRETS_FROM_ENV=1` on the daemon to skip both dotenv files. Startup and `aiur status` report missing tracker credentials, remote-dashboard credentials and allowlist, webhook secrets, non-persistent-state signing keys, and keys required by configured provider routes together by variable name; secret values are never included. Set `AIUR_STATE_PERSISTENT=1` only when the state directory survives daemon restarts; otherwise `AIUR_SECRET_KEY_BASE` is required. Hosted/container GitHub auth defaults to the App; set `AIUR_GITHUB_ALLOW_PAT=1` to explicitly allow `GITHUB_TOKEN` as the fallback.
- **Required vs optional.** Tracker configuration is required. Local GitHub startup accepts `GITHUB_TOKEN`, a `gh` keyring login via `gh auth login`, or the complete GitHub App set — `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and one of `GITHUB_APP_PRIVATE_KEY_PATH` / `GITHUB_APP_PRIVATE_KEY`. Hosted/container GitHub startup requires the App unless `AIUR_GITHUB_ALLOW_PAT=1` explicitly opts into `GITHUB_TOKEN`; the keyring is not a hosted fallback. Other integrations — webhooks, Linear, voice, dashboard, Supervisor Decision API, provider keys — are optional; absence disables the feature and is reported once at startup, never a boot failure.
- **All-or-nothing credential groups.** A partially configured group (one dashboard credential without the other, or some but not all GitHub App credentials) fails at startup naming the missing members; a fully absent group is a supported setup.
- **Type validation.** Values that fail their declared type (for example `AIUR_OPENCODE_BRIDGE_PORT=banana`) abort the boot naming the variable and what was expected, instead of failing at first use hours later.
- **Secrets never leak.** Secrets render as an empty placeholder in `.env.example` and are excluded from error text and startup warnings. No real value from any `.env` file reaches the generated example, logs, or error output.
- **Dashboard credentials/key.** Set `AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD` for machine Basic Auth and optional browser fallback. Google browser sign-in uses `AIUR_GOOGLE_CLIENT_ID` / `AIUR_GOOGLE_CLIENT_SECRET` ([GUI](/guide/gui)). `AIUR_SECRET_KEY_BASE` (at least 64 bytes, e.g. `openssl rand -base64 48`) overrides the cookie key; otherwise Aiur persists a mode-0600 key per instance under `~/.aiur/instances/`.
## Top-level
| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-00 -->
| --- | --- | --- | --- |
| `debug` | boolean | false | Enables debug-level file logging without the CLI debug flag; background runs already retain normal-level logs. |
| `executor_takeover_continuous_alert_hours` | integer | 1 | Repeated takeover advisory cadence in hours after the first; `0` disables repeats. |
| `executor_takeover_first_alert_hours` | integer | 8 | First Executor takeover advisory threshold in hours; `0` disables. |
| `hooks_file` | file pointer | none | Sibling YAML file merged as the `hooks:` block. |
| `instance.deployment_kind` | string | `operator` | Selects credential owner. Hosted operators may use subscriptions; consumers use API keys only. |
| `instance.id` | string | host and state directory | Stable id used by the shared multi-instance coordination store; read once at boot. Set `AIUR_LEASE_DATABASE_URL` to the same TLS PostgreSQL URL on each instance to enable shared ticket claims, repository leader election, and live-instance heartbeats. Remote certificates must chain to system CA roots; configured-store failures block new dispatch and live-instance reads. |
| `instance.ignore.label_prefixes` | array of strings | `[]` | Label prefixes marking tickets another instance owns. A prefix such as `nuc` matches `nuc:*` state labels. If label data is unavailable, ticket-scoped observers skip conservatively. This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
| `instance.ignore.labels` | array of strings | `[]` | Exact labels marking tickets another instance owns. If label data is unavailable, ticket-scoped observers skip conservatively. This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
| `instance.ignore.tickets` | array of integers | `[]` | Ticket numbers another instance owns. This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
| `instance.mode` | string | `local` | `hosted` adds static startup, reload, and dispatch checks for permission, network, credentials, the effective API-key-only fallback, Remote Control, local panes, and REPL isolation. Authentication for primary routes and account profiles is learned at runtime: unsafe first or later observations fail closed. Claude reauthorizes each action; Codex refuses an unsafe initial account read and later unsafe notifications before subsequent progress, tool calls, or success. Current production backends remain ineligible until #5701. Read once at daemon start; restart to change. |
| `instance.owns` | array of maps | `[]` | Ticket rules reserved for this live instance. Each entry has exactly one `label` or positive `ticket`; matching rules apply only while this instance is dispatching. Requires the shared lease store to coordinate live instances. Hot-reloadable. |
| `instance.pool` | boolean | `true` | Whether this instance may dispatch tickets that no live, dispatching instance reserves with `instance.owns`. Hot-reloadable. |
| `instance.role` | string | `primary` | `secondary` never claims the repository leader lease; `primary` is eligible to lead on equal terms with other eligible instances when `AIUR_LEASE_DATABASE_URL` is configured. Only the lease holder runs repository-wide landing, quarantine, merge-queue, and main-branch work. Label heals remain scoped to each instance's tracker view. Without a shared store, primary retains single-instance behavior. Read once at daemon start; change it with a restart. |
| `max_log_history_mb` | integer | 1000 | Caps persistent log history in MB. |
| `max_vertical_panes` | integer | 3 | Caps visible agent chat panes. |
| `pre_warmed_sessions` | integer | 3 | Number of opencode sessions booted early; 0 disables pre-warm. |
| `prompt_file` | string | nil | Per-repository Liquid prompt template. |
## executor
| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `executor.sweep.unreviewed_pr_minutes` | integer | 10 | Minutes an open, non-draft PR may wait without a review on its current head before the Executor sweep reports it, whatever its ticket state; the finding names that state. Must be positive. |
| `executor.relay_operator_answers` | boolean | false | Opt-in quoted operator answers via `operator-relay-answer`, including human-only Commands. Enabling and recording raise info alerts; disable to revoke. See [relay attribution and corrections](/concepts/commands#operator-answers-relayed-in-conversation). |

Aiur watches nonterminal tickets in the run scope and, once a ticket's **convergence age** crosses a configurable threshold, raises an advisory `needs_attention` alert visible in `aiurdev alerts --needs-attention` and the watch actionable section. The alerts are advisory takeover prompts — they never perform a takeover automatically.

- `executor_takeover_first_alert_hours` (default `8`) — a nonterminal ticket first raises the advisory once its convergence age reaches this value.
- `executor_takeover_continuous_alert_hours` (default `1`) — while the ticket stays nonterminal and unresolved, the advisory is repeated at most this often. A value of `0` disables repeats (first alert only); `0` on the first threshold disables the feature. Negative or non-integer values are rejected.

**Convergence age** is `now − min(first_observed_active_work_at, open_pr_created_at)`:

- `first_observed_active_work_at` is persisted durably per ticket in daemon state, set once the first time the monitor observes the ticket as nonterminal and in scope. A worker restart, redispatch, `max_turns` recycle, or daemon restart never resets it.
- `open_pr_created_at` is the creation time of the ticket's open PR (a floor, so an already-open PR is never hidden by a freshly installed or restarted monitor).

| Evidence | Detail |
| --- | --- |
| Identity | Ticket and PR. |
| Age | Elapsed convergence age. |
| Activity | Last material push, current live-owner state, and dispatch/restart count. |
| PR health | Base and merge freshness. |
| CI | Current state when available, for tickets already alerted. |

A ticket that becomes terminal or leaves the run scope resolves its active advisory and forgets its convergence state; a re-opened ticket starts a fresh episode.

## monitoring

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-03 -->
| --- | --- | --- | --- |
| `monitoring.daemon_heartbeat_stale_ms` | integer | 3,600,000 | Threshold in milliseconds for recording a retrospective daemon heartbeat gap on Executor startup. A durable `system.daemon.gap` informational event is emitted only when a stale heartbeat is corroborated by the lifecycle journal; its cause is `clean_shutdown` when a stop was recorded and `unknown` for an unclosed start. Missing heartbeat files are ignored. This is not live monitoring and cannot alert while Aiur is stopped. Default is 1 hour (3,600,000 ms). |

## workspace

The `wip_*` keys bound the save of uncommitted work described in [Saved uncommitted work](/reference/cli#saved-uncommitted-work).

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-05 -->
| --- | --- | --- | --- |
| `workspace.bootstrap_image` | string | nil | Docker image for warm build-cache seeding. |
| `workspace.bootstrap_image_pull` | boolean | false | Pulls the bootstrap image before seeding. |
| `workspace.root` | string path | tmp `aiur_workspaces` | Root for agent workspaces. |
| `workspace.wip_command_timeout_ms` | integer | 60000 | Time limit of each `git` and `tar` command of a save. A timeout keeps the workspace, except for a closed ticket. |
| `workspace.wip_max_bytes` | integer | 52428800 | Cap in bytes of one save of uncommitted work (50 MiB). Untracked files past it are skipped; the tracked patch is always kept. |
| `workspace.wip_max_dir_files` | integer | 10000 | An untracked directory with more files than this, or a nested repository, is skipped whole. |
| `workspace.wip_max_file_bytes` | integer | 10485760 | An untracked file larger than this (10 MiB) is skipped in a save. |
| `workspace.wip_retention_bytes` | integer | 2147483648 | Cap in bytes of all of `wip-preserved/` (2 GiB). Closed tickets' saves are pruned first. |
| `workspace.wip_retention_days` | integer | 14 | Saves older than this are pruned. The newest save of an open ticket is never pruned. |

## worker

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-06 -->
| --- | --- | --- | --- |
| `worker.max_concurrent_agents_per_host` | integer or nil | nil | Per-host concurrent-agent cap. |
| `worker.ssh_hosts` | array | `[]` | SSH hosts available for remote execution. Each server must allow `BASH_ENV`, `ENV`, `HOME`, and `ZDOTDIR` through OpenSSH `AcceptEnv`; Aiur neutralizes them before the account shell starts and fails closed if the server rejects them. |

## hooks

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-07 -->
| --- | --- | --- | --- |
| `hooks.after_create` | string or nil | nil | Command after workspace creation. |
| `hooks.after_run` | string or nil | nil | Command after each agent run. |
| `hooks.before_remove` | string or nil | nil | Command before workspace removal. |
| `hooks.before_run` | string or nil | nil | Command before each agent run. |
| `hooks.timeout_ms` | integer | 600000 | Per-hook timeout; 10 minutes by default. |

## prewarm

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-08 -->
| --- | --- | --- | --- |
| `prewarm.base_build` | string | none | One-time base build command. |
| `prewarm.base_build_file` | string | none | Sibling script loaded into `base_build`. |
| `prewarm.build_timeout_minutes` | integer | 60 | Total time allowed for a base clone, fetch, and build. |
| `prewarm.enabled` | boolean | false | Opts into one warm base checkout. |
| `prewarm.poll_seconds` | integer | 0 | Base-refresh interval; 0 disables polling. |

`poll_seconds: 0` disables periodic refreshes, not dispatch-time freshness checks.

A base refresh is bounded from clone/fetch start by `prewarm.build_timeout_minutes` (default 60); on expiry, Aiur terminates its process group and releases dispatch for cold-clone fallback. The independent idle watchdog releases a stalled dispatch hold after 10 minutes.

For the idle watchdog, "stalled" means the hold's worker is dead with no completion signal in flight. Timed-out builds are not retried automatically; restart Aiur to retry.

The `system.dispatch.prewarm_blocked` alert is not raised for a routine refresh: a freshness probe that self-clears in seconds holds dispatch too briefly to matter to an operator.

The alert fires only once a hold has persisted past the routine bound: a probe
that fails or exceeds its own timeout, a build that genuinely holds the fleet,
or a stalled hold the watchdog releases. Its `.resolved` fires when the gate
clears.

## pr_watch

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-09 -->
| --- | --- | --- | --- |
| `pr_watch.command_prefix` | string | `/aiur` | One-off trusted comment command prefix. |
| `pr_watch.enabled` | boolean | false | Enables trusted PR comment watching. |
| `pr_watch.watch_label` | string | `watch` | Label suffix enrolling a PR for watching. |

## pr_health

Periodic scan of open pull requests for conditions that stall PRs silently: a
PR authored by a configured human merger (unmergeable by construction, since
GitHub blocks self-approval), a non-draft PR older than `stale_hours` with no
review, and a rework ticket whose PR's own contribution has genuinely changed
since its blocking review.

Findings raise needs-attention alerts in the Executor's alert feed
(`system.pr_health.unmergeable_author` / `system.pr_health.stale_unreviewed` /
`system.pr_health.rework_merge_only`).

Enabling the scan enables the **rework re-queue**: a ticket in
`agent:rework` whose PR's own contribution diff (`merge-base..head`) changed
since the blocking `CHANGES_REQUESTED` review is moved to `agent:human-review`
for the second look — GitHub keeps `reviewDecision = CHANGES_REQUESTED` until
a brand-new review, so nothing else re-queues it.

It also runs the **head-verdict router** on the same interval. At the open, non-draft PR's head, the configured
reviewer's `CHANGES_REQUESTED` moves `agent:human-review`, `agent:ci-wait` or `agent:error` to `agent:rework`.

An `APPROVED` that follows their same-head `CHANGES_REQUESTED` moves `agent:rework` to `agent:ci-wait`. An error ticket
moved to rework raises `system.pr_health.error_rework`. Each review routes once.

A PR whose head only moved via merges of the base branch (own contribution unchanged) is NOT re-queued; it raises
`system.pr_health.rework_merge_only` so the merge-only state is visible distinctly from genuine rework.

A re-queue that the thread-clearance gate refuses (the reworked PR still has unresolved review threads — the normal
state of a rework ticket) raises `system.pr_health.rework_requeue_failed`; the head is not throttled on a failed
write, so the re-queue retries on the next tick instead of silently stranding the ticket in rework.

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-10 -->
| --- | --- | --- | --- |
| `pr_health.enabled` | boolean | false | Enables the PR-health scan and the rework re-queue. |
| `pr_health.interval_seconds` | integer | 1800 | How often the scan lists open PRs. |
| `pr_health.stale_hours` | integer | 24 | A non-draft PR older than this with no review is flagged. |

## events

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-11 -->
| --- | --- | --- | --- |
| `events.block_state_debounce_seconds` | integer | 10 | Debounces blocked/unblocked transitions. |
| `events.codeowners_refresh_seconds` | integer | 3600 | CODEOWNERS refresh interval. |
| `events.custom_events_per_turn_max` | integer | 5 | Caps custom events per turn. |
| `events.export.enabled` | boolean | false | Enables the external event journal; restart to apply. Reserved for the exporter; no feed is installed yet. |
| `events.export.retention_days` | integer | 7 | Retention age in days (1..90); older records are trimmed. Read at boot. |
| `events.export.retention_max_events` | integer | 50000 | Maximum retained records (1000..1000000); the first retention bound reached applies. Read at boot. |

## upgrade

The `aiur run` upgrade-version notice is optional and opt-out: it caches with a TTL (the registry is contacted at most once a day), fails open and silent when unreachable, never runs under `aiurdev`, and is channel-aware — a `nightly` or `next` user is never offered a lower `latest`.

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-12 -->
| --- | --- | --- | --- |
| `upgrade.check_enabled` | boolean | true | Enables the `aiur run` version notice and its registry check. Set false to suppress the check entirely (zero outbound calls). |

`AIUR_UPGRADE_CHECK_DISABLED` (and the legacy `AIUR_NO_UPDATE_NOTIFIER`) are the
environment-variable equivalents; the check also stays silent in CI runs.

## alerts

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-13 -->
| --- | --- | --- | --- |
| `alerts.alerts_file` | string path or nil | bundled alerts file | Topic-to-sound YAML map. |
| `alerts.enabled` | boolean | true | Master alert-sound switch. |
| `alerts.sound_dir` | string path or nil | nil | Directory for custom sound files. |
| `alerts.use_os_default_sounds` | boolean | false | Uses built-in OS sounds by category. |

## usage

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-23 -->
| --- | --- | --- | --- |
| `usage.alerts` | map | %{} | Per-provider low-usage alert thresholds; each threshold is remaining percent from 0 to 100. |

## compaction

Optional Codex thread compaction runs synchronously at the `human-review` handoff via `thread/compact/start`; other providers are unsupported, and token thresholds use cumulative usage measured by Aiur at handoff.

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-15 -->
| --- | --- | --- | --- |
| `compaction.auto_trigger.enabled` | boolean | false | Opt in to compaction when cumulative agent token usage reaches the configured threshold at human-review handoff. |
| `compaction.auto_trigger.token_threshold` | integer | 50000 | Minimum cumulative agent tokens required for threshold mode (must be at least 1000). |
| `compaction.backends` | array | [] | Must contain only `codex`; every other provider is rejected by config validation. |
| `compaction.enabled` | boolean | false | Master switch for compaction; must be true to enable any compaction features. |
| `compaction.manual_approval` | boolean | false | Explicit opt-in to compact on terminal handoff. |
| `compaction.timeout_ms` | integer | 30000 | Timeout in milliseconds for compaction API calls. |

Codex reports completion with its `thread/compacted` notification. Failure does not block normal handoff. Aiur records the result in daemon-owned state and will not retry a completed or failed attempt on that thread. A daemon restart resumes the same Codex thread from its original rollout.

**Example: manual-only compaction**
```yaml
compaction:
  enabled: true
  backends: [codex]
  manual_approval: true
  timeout_ms: 30000
```

**Example: threshold opt-in**
```yaml
compaction:
  enabled: true
  backends: [codex]
  auto_trigger:
    enabled: true
    token_threshold: 50000
```

## observability
| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-16 -->
| --- | --- | --- | --- |
| `observability.build_order_funnel_health_check` | boolean | false | Opts into one bounded startup check of the local Build Order endpoint and configured Tailscale Funnel HTTPS 443 target. Leave disabled when Funnel serves another purpose. |
| `observability.capture_github_facts` | boolean | true | Enables analytics GitHub fact and repo-timeline reads when the master capture switch is on. |
| `observability.capture_label_prefixes` | list | `["experiment:", "cohort:", "feature:"]` | Label prefixes captured at dispatch; at most 20. |
| `observability.capture_tags` | map | `%{}` | Static cohort tags; at most 20 string pairs, 64 characters per key/value. |
| `observability.dashboard_enabled` | boolean | true | Reserved compatibility setting; use the launch-time `--no-dashboard` flag to suppress the listener in foreground or background mode. |
| `observability.dashboard_writable` | boolean | true | Enables dashboard write paths. Set to `false` to disable them. A dashboard bound beyond loopback refuses to start without both dashboard basic-auth environment variables; a loopback listener binds without them and fails closed (see below). |
| `observability.refresh_ms` | integer | 1000 | Dashboard data refresh interval. |
| `observability.render_interval_ms` | integer | 16 | Minimum render interval. |
| `observability.telemetry_enabled` | boolean | true | Master analytics capture switch; restart to apply. Disabled boots append a local `analytics/capture-gaps.ndjson` marker and `/analytics` shows a capture-off notice. |
| `observability.telemetry_retention_max_age_days` | integer | 30 | Maximum retained telemetry age. |
| `observability.telemetry_retention_max_bytes` | integer | 67108864 | Maximum retained telemetry bytes. |
| `observability.telemetry_retention_prune_interval_bytes` | integer or nil | nil | Bytes between retention-prune checks. |

`dashboard_writable` controls authorization, not authentication. Set `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD` before use. A loopback listener can bind without them but rejects every dashboard request until both are set. A listener beyond loopback refuses to start without both.

When `observability.build_order_funnel_health_check` is enabled, Aiur checks the configured dashboard bind address at `/build-orders/1` and reads `tailscale funnel status --json` once after dashboard startup. Both command timeouts are five seconds, and timed-out Tailscale processes are terminated.

The one-time check is suppressed when `server.tailscale_funnel: true`. The reconciler reports Funnel health after its initial and periodic attempts, so the startup check cannot alert before reconciliation runs.

HTTP 200, redirects 301/302/304/307/308, and 401 (authentication required) count as reachable. Other statuses, including 201, 204, and 303, do not.

A stale proxy target raises `system.build_order_funnel.target_mismatch`; an unreachable endpoint raises `system.build_order_funnel.target_unreachable`; and an endpoint timeout raises `system.build_order_funnel.target_timeout`.

An unavailable or unparseable Tailscale status raises `system.build_order_funnel.health_check_error`. Tailscale is not detected or queried unless this setting is explicitly enabled.

The supervising-Executor Decision API uses the separate `AIUR_SUPERVISOR_TOKEN` bearer credential. Generate it with `openssl rand -base64 32`, then put `AIUR_SUPERVISOR_TOKEN=<generated-token>` in `~/.aiur/.env` (global) or the repository `.env` (project-local).

An exported value wins, followed by the global file and then the repository file. The value must be at least 32 bytes, bearer-safe, and free of surrounding whitespace. A present non-empty invalid value aborts startup; an absent or empty value leaves the API disabled.

## decisions

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-17 -->
| --- | --- | --- | --- |
| `decisions.supervisor_allow_non_reversible` | boolean | false | Allows supervisor policy to cover partially reversible or irreversible decisions. |
| `decisions.supervisor_allowed_kinds` | array | `[]` | Decision kinds an authenticated supervising Executor may answer. Empty means none. |

These policy keys never grant transport access by themselves. The supervisor API also requires `AIUR_SUPERVISOR_TOKEN`; mutations require the writable and origin gates described above.

## server

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-18 -->
| --- | --- | --- | --- |
| `server.allowed_hosts` | array | derived | Additional accepted Host names; the public URL host and loopback addresses are always accepted. |
| `server.host` | string | `127.0.0.1` | HTTP bind address. `0.0.0.0` exposes the dashboard to the LAN; there is no automatic Tailscale detection. |
| `server.port` | integer | 0 | HTTP port; 0 selects a free OS port. |
| `server.public_url` | string | nil | Public URL for generated links and Host/origin allowlists; loopback listeners also accept tailnet hosts. |
| `server.tailscale_funnel` | boolean | false | Reconcile an already-enabled Tailscale Funnel HTTPS route on port 443 to the dashboard's current bound host and port at startup and every 30 seconds. Requires the Tailscale CLI and an existing Funnel route; failures raise a Build Order Funnel alert and retry. |
| `server.trusted_proxies` | array | `[]` | CIDRs allowed to set X-Forwarded-* request metadata; `platform` trusts private proxy-network peers. |

Unset `server.host` binds `127.0.0.1` (or `AIUR_DEFAULT_DASHBOARD_HOST`); explicit config/`--host` override. `0.0.0.0` exposes LAN. Loopback permits `*.ts.net` Hosts and HTTPS origins while loopback-bound. For Tailscale, build and restart, set `server.public_url` (e.g. `https://<host>.ts.net:4001`), then restart again. `server.allowed_hosts` adds hosts.

Set `server.tailscale_funnel: true` only when this node already has a Funnel route the operator intends to keep. At startup and every 30 seconds, Aiur reads the dashboard's bound host and port and updates the route with `tailscale funnel --bg` when needed.

Before changing a different target, Aiur probes that target's `/build-orders/1`. Any HTTP response makes the reconciler leave the route unchanged and raise `system.build_order_funnel.target_mismatch`.

Only a connection-refused probe counts as stale and permits an update. Timeouts, TLS failures, and other probe errors leave the route unchanged and raise `system.build_order_funnel.health_check_error` with cause `unknown`. Wildcard binds (`0.0.0.0` and `::`) map to loopback for the Funnel target.

Enable this on only one Aiur daemon per node. A second can repoint the route while the owner restarts. When enabled, the reconciler suppresses `observability.build_order_funnel_health_check` and reports its own failures after each attempt.

A non-root account needs Tailscale operator access before Aiur can manage the route. Grant it with `sudo tailscale set --operator=$USER`; then run Aiur as that account. Aiur does not enable Funnel or create a route. Dashboard authentication remains in place, and the route supports HTTP and WebSocket traffic.

The target probe is a bounded liveness check, not proof of daemon identity or route ownership. A live stale service requires operator intervention. Aiur does not restart, stop, or otherwise manage the Tailscale daemon.

A fixed `server.port` that is already bound — for example a second `aiur` instance on the same host — does not crash the daemon. The second instance logs an explicit startup message naming the port and the conflict, disables only its own dashboard, and keeps running agents.

The durable repository Executor state also records every daemon start and stop in `<repo>.control-lifecycle.json`, with the invoking process's OS pid, parent pid, and hostname. All runs for that repository share the journal, so a second instance or a crash is identifiable after the fact even when each run has a different log directory.

## dashboard_auth
| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-22 -->
| --- | --- | --- | --- |
| `dashboard_auth.browser_basic_auth` | boolean | true | Allows Basic Auth fallback on browser pages; API and Stream Deck machine clients keep Basic Auth. |
| `dashboard_auth.google.allowed_emails` | array | `[]` | Exact email allowlist for Google OpenID Connect; an empty list disables Google sign-in. |
| `dashboard_auth.passkeys` | boolean | false | Enables passkey login and enrollment after a fresh Google sign-in. |
| `dashboard_auth.session_max_age_days` | integer | 30 | Maximum dashboard browser session age in days. |
## build_queue
Build queue configuration for GitHub workflows (Linear is unsupported); the daemon reconciles stored queue membership after tracker signals or on the configured interval, with a two-second debounce.

| Key | Type | Default | Description | <!-- generated-reference:config-configuration-21 -->
| --- | --- | --- | --- |
| `build_queue.enabled` | boolean | true | Enable build queue reconciliation. The server maintains dispatch hints, promotes ready items, and withdraws todo from unclaimed items whose prerequisites change. Disabling the queue removes its server and hints table on the next run. |
| `build_queue.max_active_sets` | integer or null | nil | Maximum sets with started, unfinished members (including CI/review waits); minimum 1. Null lets capacity decide. Held sets do not consume this cap; existing runners are never preempted. |
| `build_queue.max_writes_per_minute` | integer | 20 | Queue write budget per minute; 1..60. |
| `build_queue.merged_open_grace_seconds` | integer | 600 | Grace period in seconds for an `issue_closed` queue prerequisite whose PR merged but issue remains open; 60..86400. |
| `build_queue.observation_max_age_seconds` | integer or null | derived (2× polling.interval_seconds) | Maximum observation age in seconds; null derives twice the base poll interval (240 seconds by default); explicit values must be 10..3600. A non-empty queue whose open-issue snapshot is older than this lists open issues itself, at most once per this age. |
| `build_queue.optimistic_churn_attention_threshold` | integer | 3 | Conflicting integrations before an informational attention; 0 disables, 0..50. Never pauses work. |
| `build_queue.optimistic_failure_grace_seconds` | integer | 600 | Seconds to wait for a reopened or replacement blocker PR before parking optimistic dependents; 60..86400. |
| `build_queue.optimistic_slot_share` | float | 0.5 | Fleet-wide optimistic share, 0..1. Zero disables optimistic dispatch; otherwise the cap is max(1, floor(share × effective agent limit)). Ready work starts first; merged blockers free share on the next cycle. Running agents are never preempted. |
| `build_queue.reconcile_interval_seconds` | integer | 60 | Reconciliation interval in seconds; 10..3600. |
| `build_queue.set_order` | string | `none` | `none` preserves ordinary candidate ordering. Opt into `ranked` to prefer queue sets by persisted rank (creation order by default); ready members follow list position, while optimistic members retain deepest-first ordering within each set. Ready work always precedes optimistic work. With a cap or reserve configured, earlier unknown or stale readiness blocks ranked spill because it may have ready work. Held sets remain stopped. Main CI fixer tickets dispatch ahead of ranked sets. |
| `build_queue.spill_reserve_slots` | integer | 0 | Slots kept free for the earliest unfinished, unheld set before admitting later-set work; minimum 0. Reserve applies even while that set waits on review. Set-policy waits appear as `queue_set_order` in status and queue show. |
| `build_queue.start_trigger` | string | `pr_merged` | Prerequisite stage needed for queue promotion: `issue_closed`, `pr_merged`, `pr_approved`, `pr_ci_green`, or `pr_opened`. Also governs native dependency dispatch. Override with `queue add --start-on` or `queue set NAME --start-on`; `default` follows config. Missing or stale evidence never releases dependents. Optimistic stages combine lifecycle labels with retained per-PR progress. `pr_approved` adds one conditional review read per watched blocker. Linear dependency dispatch supports only `issue_closed` and `pr_merged`. See [Start trigger](/concepts/build-orders#start-trigger). |
## Further sections
- [`agent`, host-pressure admission, `agent.claude`, `agent.codex`, model discovery](/reference/configuration-agent)
- [`build_order` and resolution notes](/reference/configuration-build-order)

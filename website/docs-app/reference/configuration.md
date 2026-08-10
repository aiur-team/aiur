# Configuration reference

Configuration lives in `.aiur/config` (YAML); legacy `.aiurconfig` is also accepted. `prompt_file:` and `hooks_file:` point at sibling files. Supported secret and workspace-root fields resolve `~` and `$VAR` values; other path fields do not generally expand environment references.

## Top-level

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `max_vertical_panes` | integer | 3 | Caps visible agent chat panes. |
| `pre_warmed_sessions` | integer | 3 | Number of opencode sessions booted early; 0 disables pre-warm. |
| `max_log_history_mb` | integer | 1000 | Caps persistent log history in MB. |
| `prompt_file` | string | nil | Per-repository Liquid prompt template. |
| `debug` | boolean | false | Enables file logging without the CLI debug flag. |
| `hooks_file` | file pointer | none | Sibling YAML file merged as the `hooks:` block. |

## tracker

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `tracker.kind` | string | required | Selects `linear`, `github`, or `memory`. |
| `tracker.base_branch` | string | repo default | Branch agents target with PRs. |
| `tracker.active_states` | array | tracker-specific | States eligible for dispatch. GitHub values are lifecycle label slugs such as `todo` and `in-progress`, not display names. |
| `tracker.terminal_states` | array | tracker-specific | States that stop work. GitHub values are lifecycle label slugs such as `done`. |
| `tracker.terminal_fence_grace_seconds` | integer | 30 | How long a terminal tracker observation remains lifecycle-fenced while an authoritative queued item is still undelivered. |
| `tracker.github.repo` | string | required for GitHub | GitHub owner/name used by Aiur. |
| `tracker.github.label_prefix` | string | `agent` | Prefixes lifecycle labels. |
| `tracker.github.bot_account` | string | nil | Login identity Aiur recognizes as its own to suppress self-triggered comment/event loops. This is an identity, not the credential: `GITHUB_TOKEN` is the credential Aiur authenticates with. `aiur init` defaults it to the token's login; prefer a dedicated bot account when operators also comment from a trusted CODEOWNER account. In a non-interactive or `--force` run the wizard applies the detected token login, or omits the key entirely when no login can be detected. Re-running `aiur init` preserves an existing value. |
| `tracker.github.trusted_accounts` | array | `[]` | Usernames allowed to direct agents. |
| `tracker.github.allowed_users` | array | `[]` | GitHub logins allowed to use trusted operator paths. |
| `tracker.github.human_mergers` | array | `[]` | GitHub logins allowed to perform human merge actions. |
| `tracker.github.planning_root_limit` | integer | 4 | Maximum Build Order planning roots fetched in one cycle. |
| `tracker.github.planning_page_budget` | integer | 4 | Maximum GitHub planning pages fetched in one cycle. |
| `tracker.github.planning_call_budget` | integer | 4 | Maximum GitHub planning calls fetched in one cycle. |
| `tracker.linear.api_key` | string | env fallback | Linear API key; `$VAR` resolves from the environment. |
| `tracker.linear.project_slug` | string | nil | Linear project polled by Aiur. |
| `tracker.linear.endpoint` | string | `https://api.linear.app/graphql` | Linear GraphQL endpoint. |
| `tracker.linear.assignee` | string | env fallback | Linear assignee filter. |

## polling

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `polling.interval_seconds` | integer | 30 | Seconds between tracker polls. |
| `polling.usage_interval_seconds` | integer | 300 | Seconds between provider-meter probes. Values below 120 are rejected to avoid provider rate-limit degradation. |

## workspace

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `workspace.root` | string path | tmp `aiur_workspaces` | Root for agent workspaces. |
| `workspace.bootstrap_image` | string | nil | Docker image for warm build-cache seeding. |
| `workspace.bootstrap_image_pull` | boolean | false | Pulls the bootstrap image before seeding. |

## worker

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `worker.ssh_hosts` | array | `[]` | SSH hosts available for remote execution. |
| `worker.max_concurrent_agents_per_host` | integer or nil | nil | Per-host concurrent-agent cap. |

## agent

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `agent.kind` | string | `codex` | Default coding backend; an explicit value wins, otherwise a `claude:` section infers `claude`, a `codex:` section infers `codex`, and no backend section falls back to `codex`. |
| `agent.remote_control` | boolean | false | Opts RC-capable backends into remote control. |
| `agent.prior_work_continuation` | boolean | true | Lets a resumed ticket continue existing workspace work when policy permits. |
| `agent.max_dispatches_per_ticket` | integer | 0 | Per-ticket dispatch latch; 0 disables the latch. |
| `agent.max_concurrent_agents` | integer or nil | derived from host capacity | Global simultaneous-agent cap. When omitted, it derives from the measured host capacity: `schedulers + schedulers / 4` (e.g. 20 on a 16-core host), so the ceiling is calibrated to the box instead of a hard-coded count. Explicit config wins. The load envelope reduces effective concurrency below this ceiling under host pressure. |
| `agent.max_concurrent_builds` | integer | 2 | Caps local agent Mix verification; 0 deliberately disables the concurrency cap. When every build slot is busy or builds are queued, the dispatch gate defers new admissions (`build` capacity hold). |
| `agent.build_start_stagger_seconds` | integer | 0 | Minimum spacing between local Mix build starts; 0 disables pacing. |
| `agent.min_free_memory_mb` | integer or nil | nil | Linux `MemAvailable` floor shared by dispatch and the Mix build gate. |
| `agent.max_concurrent_agents_by_state` | map | `%{}` | Per-state caps overriding the global cap. |
| `agent.routing` | map | `%{}` | Maps complexity levels to backend/model/effort routing. |
| `agent.switch_model_on_ratelimit` | array | `[]` | Opt-in backend order for a new claim when a model is rate-limited. |
| `agent.rate_limit_fallback` | string | `claude` | Automatic recovery backend for an already-running Codex agent; `""` disables it. |
| `agent.complexity_prompts` | map | `%{}` | Adds prompt guidance by complexity level. |
| `agent.max_turns` | integer or nil | nil | Per-issue turn cap; nil is uncapped. |
| `agent.max_retry_attempts` | integer | 3 | Failed-turn retry count. |
| `agent.max_retry_backoff_ms` | integer | 300000 | Retry backoff ceiling in milliseconds. |
| `agent.turn_timeout_ms` | integer | 3600000 | Backstop timeout for one turn. |
| `agent.stall_timeout_ms` | integer | 3600000 | Silent-agent watchdog; 0 disables it. |
| `agent.max_agent_duration_minutes` | integer | 60 | Active-runtime pause checkpoint; 0 disables it. |
| `agent.ci_wait_rewake_minutes` | positive integer | 5 | Re-wakes a CI-wait-paused agent for one recovery check when no terminal event arrives. |
| `agent.max_load_average` | float | 1.5 | Holds dispatch above the load threshold; null disables it. |
| `agent.target_load_average` | float | 1.0 | Adaptive per-scheduler load target; null disables the adaptive envelope. |
| `agent.run_queue_threshold` | float or nil | nil | Per-scheduler runnable-process ceiling for the instantaneous run-queue dispatch gate; null disables it (the 1-minute load gate still applies). When enabled, new dispatch holds while `procs_running` exceeds `run_queue_threshold × schedulers`, catching short CPU bursts the lagging load average smooths out (`run_queue` capacity hold). |
| `agent.load_ramp_step` | integer | 1 | Capacity increase while load is below the target. |
| `agent.load_cooldown_seconds` | integer | 60 | Minimum interval between adaptive capacity reductions. |
| `agent.synthetic_load_process_cap` | integer or nil | nil | Caps synthetic load processes; 0 disables the guard. |
| `agent.backend_configs` | map | `%{}` | Provider-specific configuration, including enablement and credentials for OpenAI-compatible backends. |
| `agent.rate_limit_primary` | string | default backend | Primary backend watched for automatic rate-limit recovery. |
| `agent.max_turns_by_complexity` | map | `%{}` | Per-complexity turn caps. |
| `agent.mix_scheduler_cap` | integer | 4 | Caps schedulers in agent-launched Mix BEAMs. |
| `agent.saturation_log_enabled` | boolean | true | Records host and VM diagnostics when sustained load crosses the saturation threshold. |

Enabled local Codex `workspaceWrite` turns preserve configured/workspace/Git roots and
also grant the canonical shared build-gate metadata directory. Host-prepared lock inodes
live in a sibling `.locks` directory that is excluded from turn-writable roots, preventing
a sandbox from replacing a held slot. Gate coordination failures return status `125`
without running Mix. Repair the reported metadata/lock directory, `flock`, or `python3`
subreaper dependency and
restart/re-dispatch agents. If `aiur status` reports `BUILD GATE DEGRADED`, first stop the
old fleet and confirm no old Mix verification is live, then clear only the reported legacy
records. To disable build admission completely, set `agent.max_concurrent_builds: 0`, set
`agent.build_start_stagger_seconds: 0`, and omit `agent.min_free_memory_mb`. This explicit
opt-out removes every build safeguard; it is never an automatic error fallback.

## Host-pressure fleet admission

New fleet admissions are admitted against the total observed host pressure, not a
hard-coded process count. Every signal is optional and fails open when disabled or
unreadable (e.g. non-Linux hosts):

- **CPU load** (`agent.max_load_average`) and the **adaptive AIMD envelope**
  (`agent.target_load_average`, `agent.load_ramp_step`, `agent.load_cooldown_seconds`)
  reduce and re-ramp effective capacity as the 1-minute load crosses its per-scheduler
  targets.
- **Run queue** (`agent.run_queue_threshold`) reacts instantly to `procs_running` spikes
  that the lagging load average smooths out.
- **Available memory** (`agent.min_free_memory_mb`), **file descriptors** (a 10% open-file
  reserve), **concurrent build pressure** (`agent.max_concurrent_builds`), and
  **configured provider limits** (when every dispatchable backend reports usage-limited)
  each defer new dispatch while saturated.
- **Recovery is automatic and bounded**: gates fail open the moment pressure clears, and
  the AIMD envelope re-ramps within its cooldown window. There is no permanent cap reduction or
  starvation.

While a hold is active the fleet surfaces the binding signal and threshold: idle
dispatchable rows read `backing off`, the dashboard/status carry a `capacity_hold` block
naming the measured signal and threshold, telemetry records `capacity_hold` /
`capacity_resumed`, and a debounced `system.fleet.capacity.backoff` alert fires so an
Executor can tell capacity backoff apart from an idle or broken fleet. This limits only
**new** admissions. Running agents and agent-spawned sub-agents are never terminated.

## agent.claude

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `agent.claude.command` | string | `aiur-claude` | Command launching the Claude backend. |
| `agent.claude.model` | string or nil | nil | Optional Claude model override. |
| `agent.claude.permission_mode` | string | `bypassPermissions` | Claude permission mode. |

## agent.codex

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `agent.codex.command` | string | `codex app-server` | Command launching the Codex app server. |
| `agent.codex.approval_policy` | string or map | `untrusted` | Runtime policy: `untrusted`, `on-failure`, `on-request`, `granular`, or `never`. |
| `agent.codex.thread_sandbox` | string | `workspace-write` | Thread sandbox mode. |
| `agent.codex.turn_sandbox_policy` | map or nil | nil | Explicit per-turn sandbox policy. |
| `agent.codex.read_timeout_ms` | integer | 5000 | Codex app-server read timeout. |
| `agent.codex.thrash_max_per_window` | integer | 6 | Rapid restart limit per window. |
| `agent.codex.thrash_window_seconds` | integer | 60 | Thrash-counting sliding window. |

## hooks

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `hooks.after_create` | string or nil | nil | Command after workspace creation. |
| `hooks.before_run` | string or nil | nil | Command before each agent run. |
| `hooks.after_run` | string or nil | nil | Command after each agent run. |
| `hooks.before_remove` | string or nil | nil | Command before workspace removal. |
| `hooks.timeout_ms` | integer | 600000 | Per-hook timeout; 10 minutes by default. |

## prewarm

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `prewarm.enabled` | boolean | false | Opts into one warm base checkout. |
| `prewarm.base_build` | string | none | One-time base build command. |
| `prewarm.base_build_file` | string | none | Sibling script loaded into `base_build`. |
| `prewarm.poll_seconds` | integer | 0 | Base-refresh interval; 0 disables polling. |

## pr_watch

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `pr_watch.enabled` | boolean | false | Enables trusted PR comment watching. |
| `pr_watch.watch_label` | string | `watch` | Label suffix enrolling a PR for watching. |
| `pr_watch.command_prefix` | string | `/aiur` | One-off trusted comment command prefix. |

## events

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `events.block_state_debounce_seconds` | integer | 10 | Debounces blocked/unblocked transitions. |
| `events.custom_events_per_turn_max` | integer | 5 | Caps custom events per turn. |
| `events.codeowners_refresh_seconds` | integer | 3600 | CODEOWNERS refresh interval. |

## alerts

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `alerts.enabled` | boolean | true | Master alert-sound switch. |
| `alerts.use_os_default_sounds` | boolean | false | Uses built-in OS sounds by category. |
| `alerts.sound_dir` | string path or nil | nil | Directory for custom sound files. |
| `alerts.alerts_file` | string path or nil | bundled alerts file | Topic-to-sound YAML map. |

## observability

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `observability.dashboard_enabled` | boolean | true | Reserved compatibility setting; use the launch-time `--no-dashboard` flag to suppress the listener in foreground or background mode. |
| `observability.dashboard_writable` | boolean | true | Enables dashboard write paths. The listener refuses to start without both dashboard basic-auth environment variables. |
| `observability.refresh_ms` | integer | 1000 | Dashboard data refresh interval. |
| `observability.render_interval_ms` | integer | 16 | Minimum render interval. |
| `observability.telemetry_enabled` | boolean | true | Records run telemetry for analytics. |
| `observability.telemetry_retention_max_bytes` | integer | 67108864 | Maximum retained telemetry bytes. |
| `observability.telemetry_retention_max_age_days` | integer | 30 | Maximum retained telemetry age. |
| `observability.telemetry_retention_prune_interval_bytes` | integer or nil | nil | Bytes between retention-prune checks. |

`dashboard_writable` is an authorization gate, not an authentication mechanism. Writable dashboards, including the default loopback dashboard, require `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`; a read-only loopback dashboard does not. The supervising-Executor Decision API uses the separate `AIUR_SUPERVISOR_TOKEN` bearer credential.

## GitHub webhook receiver

`POST /api/v1/github/webhook` accepts GitHub webhook deliveries. It has no configuration keys and no bearer credential: every delivery is authenticated by the `X-Hub-Signature-256` HMAC-SHA256 digest GitHub computes over the raw request body, using the shared secret in `AIUR_GITHUB_WEBHOOK_SECRET`. Set that variable to the same secret configured on the GitHub webhook.

The receiver fails closed. A delivery is rejected with `401` when the signature header is absent, malformed, or does not match, and when `AIUR_GITHUB_WEBHOOK_SECRET` is unset or blank — the latter also raises a needs-attention `system.github_webhook.secret_missing` alert, because a misconfigured deployment must never accept unsigned deliveries. The legacy SHA-1 `X-Hub-Signature` header is ignored and is never accepted as a fallback. Deliveries larger than 25 MB, GitHub's own delivery ceiling, are refused.

## decisions

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `decisions.supervisor_allowed_kinds` | array | `[]` | Decision kinds an authenticated supervising Executor may answer. Empty means none. |
| `decisions.supervisor_allow_non_reversible` | boolean | false | Allows supervisor policy to cover partially reversible or irreversible decisions. |

These policy keys never grant transport access by themselves. The supervisor API also requires `AIUR_SUPERVISOR_TOKEN`; mutations require the writable and origin gates described above.

## server

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `server.port` | integer | 0 | HTTP port; 0 selects a free OS port. |
| `server.host` | string | `127.0.0.1` | HTTP bind address. |

## opencode

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `opencode.command` | string | `opencode` | Command launching opencode. |
| `opencode.bridge_port` | integer | 4097 | Aiur↔opencode bridge port. |
| `opencode.bridge_host` | string | `127.0.0.1` | Aiur↔opencode bridge host. |
| `opencode.serve_args` | array | `[]` | Extra `opencode serve` arguments. |
| `opencode.model_prefix` | string | `aiur` | Prefix for registered synthetic models. |
| `opencode.prewarm_disabled` | boolean | false | Disables opencode session pre-warming. |

## build_order

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `build_order.ticket_detail_freshness_ms` | integer | 30000 | Freshness window for cached ticket detail. |
| `build_order.ticket_detail_max_entries` | integer | 32 | Maximum cached ticket-detail entries. |
| `build_order.ticket_detail_max_description_bytes` | integer | 16384 | Maximum cached ticket-description size. |
| `build_order.ticket_history_limit` | integer | 50 | Maximum ticket history records per view. |
| `build_order.ticket_history_max_identities` | integer | 100 | Maximum distinct ticket identities retained in history. |
| `build_order.ticket_history_stale_after_ms` | integer | 60000 | Age after which ticket history is stale. |
| `build_order.graph_catalog_refresh_ms` | integer | 60000 | Catalog refresh cadence. |
| `build_order.graph_selected_refresh_ms` | integer | 15000 | Selected Build Order refresh cadence. |
| `build_order.graph_demand_refresh_ms` | integer | 5000 | Demand-driven selected-graph refresh cadence. |
| `build_order.graph_refresh_timeout_ms` | integer | 30000 | Maximum graph-refresh request duration. |
| `build_order.graph_max_selected_roots` | integer | 32 | Maximum selected Build Order roots. |
| `build_order.graph_max_inflight` | integer | 4 | Maximum concurrent graph refreshes. |

## Resolution & validation notes

- An unset or blank `prompt_file` falls back to the built-in default prompt; a configured unreadable path fails startup.
- A legacy top-level `linear:` section is merged into `tracker.linear`.
- Only `$VAR` environment references resolve; legacy `env:NAME` values remain literal.
- `polling.interval_ms` is rejected by the loader; use `interval_seconds`.

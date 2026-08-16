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
| `tracker.base_branch` | string | required | Branch agents target with PRs. `aiur init` offers the repository default read from GitHub, but there is no runtime fallback: an unset value raises. |
| `tracker.active_states` | array | tracker-specific | States eligible for dispatch. GitHub values are lifecycle label slugs such as `todo` and `in-progress`, not display names. |
| `tracker.terminal_states` | array | tracker-specific | States that stop work. GitHub values are lifecycle label slugs such as `done`. |
| `tracker.terminal_fence_grace_seconds` | integer | 30 | How long a terminal tracker observation remains lifecycle-fenced while an authoritative queued item is still undelivered. |
| `tracker.github.max_inflight` | integer | 4 | Cap on concurrent tracker HTTP requests across all endpoints (1-100). |
| `tracker.github.max_inflight_per_endpoint` | integer | 2 | Cap on concurrent requests to any single tracker endpoint (1-100). Must not exceed `tracker.github.max_inflight`. |
| `tracker.github.requests_per_minute` | integer | 120 | Tracker request budget per minute (1-10000). Lower it when the tracker rate-limits Aiur. |
| `tracker.github.stagger_ms` | integer | 75 | Delay inserted between tracker requests, in milliseconds (0-5000), so a poll cycle does not burst. |
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
| `polling.interval_seconds` | integer | 120 | Seconds between tracker polls. The repo-events firehose shares this tick. |
| `polling.usage_interval_seconds` | integer | 300 | Seconds between provider-meter probes. Values below 120 are rejected to avoid provider rate-limit degradation. |

## webhooks

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `webhooks.repos` | list of `owner/name` | `[]` | Repos expected to deliver webhooks. A hint only. A listed repo keeps polling at full rate until it actually delivers. |
| `webhooks.silence_threshold_seconds` | integer | 900 | How long a proven repo may go without a delivery before it degrades back to full polling and raises a needs-attention alert. |
| `webhooks.sweep_interval_seconds` | integer | 60 | How often proven repos are checked for silence. |
| `webhooks.poll_widen_factor` | float | 2.0 | Multiplier applied to `polling.interval_seconds` for repos proven webhook-backed. Values below 1.0 are rejected. |

See [GitHub polling and webhooks](/apis/github) for the setup story and runtime states.

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
| `agent.priority` | array | `[]` | Ordered dispatch preference. Presence in the array makes a backend dispatchable; the first available entry is the default backend; and when a backend hits a token or usage limit aiur falls back to the next one in the list, returning to an earlier one once it recovers. When non-empty it replaces `agent.kind`, `agent.switch_model_on_ratelimit`, and the `backend_configs.<b>.enabled` opt-in. |
| `agent.kind` | string | `codex` | Deprecated default backend; ignored when `agent.priority` is non-empty. |
| `agent.remote_control` | boolean | false | Opts RC-capable backends into remote control. |
| `agent.prior_work_continuation` | boolean | true | Lets a resumed ticket continue existing workspace work when policy permits. |
| `agent.max_dispatches_per_ticket` | integer | 0 | Per-ticket dispatch latch; 0 disables the latch. |
| `agent.max_concurrent_agents` | integer or nil | derived from host capacity | Global simultaneous-agent cap. When omitted, it derives from the measured host capacity: `schedulers + schedulers / 4` (e.g. 20 on a 16-core host), so the ceiling is calibrated to the box instead of a hard-coded count. Explicit config wins. The load envelope reduces effective concurrency below this ceiling under host pressure. |
| `agent.max_concurrent_builds` | integer | 2 | Caps local agent Mix verification; 0 deliberately disables the concurrency cap. When every build slot is busy or builds are queued, the dispatch gate defers new admissions (`build` capacity hold). |
| `agent.build_start_stagger_seconds` | integer | 0 | Minimum spacing between local Mix build starts; 0 disables pacing. |
| `agent.min_free_memory_mb` | integer or nil | nil | Linux `MemAvailable` floor shared by dispatch and the Mix build gate. |
| `agent.max_concurrent_agents_by_state` | map | `%{}` | Per-state caps overriding the global cap. |
| `agent.routing` | map | `%{}` | Maps complexity levels to backend/model/effort routing. |
| `agent.switch_model_on_ratelimit` | array | `[]` | Deprecated claim-time fallback order; ignored when `agent.priority` is non-empty. |
| `agent.rate_limit_fallback` | string | `claude` | Deprecated automatic recovery backend for an already-running agent; derived from the first eligible `agent.priority` entry after the primary when set; `""` disables it. |
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
| `agent.backend_configs` | map | `%{}` | Provider-specific configuration, including per-backend settings and credentials for OpenAI-compatible backends. A backend listed in `agent.priority` is enabled automatically. |
| `agent.rate_limit_primary` | string | default backend | Deprecated primary backend watched for automatic rate-limit recovery; derived from `agent.priority` when set. |
| `agent.max_turns_by_complexity` | map | `%{}` | Per-complexity turn caps. |
| `agent.mix_scheduler_cap` | integer | 4 | Caps schedulers in agent-launched Mix BEAMs. |
| `agent.saturation_log_enabled` | boolean | true | Records host and VM diagnostics when sustained load crosses the saturation threshold. |

| Build-gate behavior | Detail |
| --- | --- |
| Writable roots | Local Codex `workspaceWrite` turns preserve configured, workspace, and Git roots and add the shared build-gate metadata directory. |
| Lock safety | Host-prepared lock inodes live in a sibling `.locks` directory outside turn-writable roots. |
| Coordination failure | Returns status `125` without running Mix. Repair the named directory, `flock`, or `python3` subreaper dependency, then redispatch. |
| `BUILD GATE DEGRADED` | Stop the old fleet, confirm no old Mix verification remains, then clear only the reported legacy records. |
| Explicit opt-out | Set `agent.max_concurrent_builds: 0`, set `agent.build_start_stagger_seconds: 0`, and omit `agent.min_free_memory_mb`. This removes every build safeguard. |

## Host-pressure fleet admission

Fleet admission uses total host pressure instead of a hard-coded process count, and disabled or unreadable signals fail open.

| Signal | Admission behavior |
| --- | --- |
| CPU load and adaptive AIMD envelope | `agent.max_load_average`, `agent.target_load_average`, `agent.load_ramp_step`, and `agent.load_cooldown_seconds` reduce and re-ramp capacity around per-scheduler targets. |
| Run queue | `agent.run_queue_threshold` reacts to `procs_running` spikes before the one-minute load average catches up. |
| Memory, file descriptors, build pressure, and provider limits | Defer new dispatch while their configured reserve or limit is exhausted. |
| Recovery | Gates reopen when pressure clears, and AIMD re-ramps within its cooldown window. |

| Hold signal | Where it appears |
| --- | --- |
| Idle rows | `backing off` |
| Dashboard and status | `capacity_hold` with the measured signal and threshold |
| Telemetry | `capacity_hold` and `capacity_resumed` |
| Alert feed | Debounced `system.fleet.capacity.backoff` |

Holds limit only new admissions. Running agents and agent-spawned sub-agents continue.

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

## elevenlabs

This optional section sends Stream Deck dictation through ElevenLabs speech-to-text and delivers the transcript through the Dashboard operator-message path; omitting it uses the defaults below.

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `elevenlabs.api_key` | string or nil | nil | ElevenLabs speech-to-text credential. Accepts a literal value or a `$ELEVENLABS_API_KEY` environment reference. |
| `elevenlabs.language_code` | string | `eng` | ISO-639-3 transcription language. ElevenLabs uses `eng` for English. |

`ELEVENLABS_API_KEY` is the environment variable for the credential. An explicit `elevenlabs.api_key` value wins; when the key is absent, or is the `$ELEVENLABS_API_KEY` reference, the variable supplies it. An environment variable set to the empty string resolves to no key.

The key is a secret. Keep it in `.env` and leave the `$ELEVENLABS_API_KEY` reference in the config file rather than pasting the value there. Aiur never logs the key, and the daemon scrubs every `*_API_KEY` variable, `ELEVENLABS_API_KEY` included, from agent process environments, local and SSH-launched alike, so no coding agent inherits it.

Configuring the key also adds an ElevenLabs meter to the Dashboard Units page, beside the GitHub API meter. It reads the account credit quota from `GET /v1/user/subscription`; with no key configured the meter is absent entirely. See [API meters](/concepts/units#api-meters) for what the figure does and does not measure.

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
| `server.host` | string | launcher-selected | HTTP bind address. An explicit value wins over the launcher's authenticated Tailscale-or-loopback default. |

When `server.host` is absent, a normal `aiur` launch uses the machine's Tailscale IPv4 if dashboard credentials are configured and otherwise uses `127.0.0.1`. A configured value is never replaced by that default. An explicit `--host` remains the highest-precedence override.

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
| `build_order.graph_catalog_labels_refresh_ms` | integer | 600000 | Cadence for the costlier catalog read that resolves epic and wave counts. |
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

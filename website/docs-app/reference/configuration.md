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
| `hooks_file` | file pointer | — | Sibling YAML file merged as the `hooks:` block. |

## tracker

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `tracker.kind` | string | — | Selects `linear`, `github`, or `memory`. |
| `tracker.base_branch` | string | repo default | Branch agents target with PRs. |
| `tracker.active_states` | array | tracker-specific | States eligible for dispatch. GitHub values are lifecycle label slugs such as `todo` and `in-progress`, not display names. |
| `tracker.terminal_states` | array | tracker-specific | States that stop work. GitHub values are lifecycle label slugs such as `done`. |
| `tracker.github.repo` | string | — | GitHub owner/name used by Aiur. |
| `tracker.github.label_prefix` | string | `agent` | Prefixes lifecycle labels. |
| `tracker.github.bot_account` | string | nil | Account Aiur replies as or recognizes. |
| `tracker.github.trusted_accounts` | array | `[]` | Usernames allowed to direct agents. |
| `tracker.linear.api_key` | string | env fallback | Linear API key; `$VAR` resolves from the environment. |
| `tracker.linear.project_slug` | string | nil | Linear project polled by Aiur. |
| `tracker.linear.endpoint` | string | `https://api.linear.app/graphql` | Linear GraphQL endpoint. |
| `tracker.linear.assignee` | string | env fallback | Linear assignee filter. |

## polling

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `polling.interval_seconds` | integer | 30 | Seconds between tracker polls. |

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
| `agent.kind` | string | claude | Default coding backend; an explicit value wins, otherwise a `claude:` section infers `claude`, a `codex:` section infers `codex`, and no backend section falls back to `claude`. |
| `agent.remote_control` | boolean | false | Opts RC-capable backends into remote control. |
| `agent.max_concurrent_agents` | integer | 10 | Global simultaneous-agent cap. |
| `agent.max_concurrent_builds` | integer | 2 | Caps local agent Mix verification; 0 deliberately disables the concurrency cap. |
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
| `agent.load_ramp_step` | integer | 1 | Capacity increase while load is below the target. |
| `agent.load_cooldown_seconds` | integer | 60 | Minimum interval between adaptive capacity reductions. |
| `agent.synthetic_load_process_cap` | integer or nil | nil | Caps synthetic load processes; 0 disables the guard. |
| `agent.mix_scheduler_cap` | integer or nil | nil | Caps schedulers in agent-launched Mix BEAMs; nil leaves them uncapped. |

Enabled local Codex `workspaceWrite` turns preserve configured/workspace/Git roots and
also grant the canonical shared build-gate directory. Gate coordination failures return
status `125` without running Mix. Repair the reported directory or `flock` dependency and
restart/re-dispatch agents. If `aiur status` reports `BUILD GATE DEGRADED`, first stop the
old fleet and confirm no old Mix verification is live, then clear only the reported legacy
records. Setting `agent.max_concurrent_builds: 0` is an explicit opt-out that removes the
fleet cap; it is never an automatic error fallback.

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
| `agent.codex.approval_policy` | string | `untrusted` | Runtime policy: `untrusted`, `on-failure`, `on-request`, `granular`, or `never`. |
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
| `prewarm.base_build` | string | — | One-time base build command. |
| `prewarm.base_build_file` | string | — | Sibling script loaded into `base_build`. |
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
| `observability.dashboard_writable` | boolean | false | Enables dashboard write paths. |
| `observability.refresh_ms` | integer | 1000 | Dashboard data refresh interval. |
| `observability.render_interval_ms` | integer | 16 | Minimum render interval. |

`dashboard_writable` is an authorization gate, not an authentication mechanism. Writable or non-loopback dashboards also require `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`. The supervising-Executor Decision API uses the separate `AIUR_SUPERVISOR_TOKEN` bearer credential.

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

## Resolution & validation notes

- An unset or blank `prompt_file` falls back to the built-in default prompt; a configured unreadable path fails startup.
- A legacy top-level `linear:` section is merged into `tracker.linear`.
- Only `$VAR` environment references resolve; legacy `env:NAME` values remain literal.
- `polling.interval_ms` is rejected by the loader; use `interval_seconds`.

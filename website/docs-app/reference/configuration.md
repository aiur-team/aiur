# Configuration reference

Configuration lives in `.aiur/config` (YAML), and `prompt_file:` and `hooks_file:` point at sibling files.

Older root-level config files are rejected. When moving one, also move the files it references, or rewrite their paths so they still resolve from the new config directory.

Supported secret and workspace-root fields resolve `~` and `$VAR` values; other path fields do not generally expand environment references.

## Environment variables

Environment variables are declared once in the env schema (`Aiur.Env.Schema`), which validates them at startup and generates the checked-in `.env.example` (run `mix aiur.env.example` from `src/` to regenerate; a CI check fails when the example drifts from the schema).

- **Layering.** The launcher reads `~/.aiur/.env` then `./.env`, each file filling only unset names, so the home file wins. When both files set the same variable to different values, the repo value is silently dead and the daemon logs a startup warning naming the variable (never its value).
- **Required vs optional.** The only configuration that aborts a boot is the GitHub credential (`GITHUB_TOKEN`, a `gh` keyring login via `gh auth login`, or the complete GitHub App set — `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and one of `GITHUB_APP_PRIVATE_KEY_PATH` / `GITHUB_APP_PRIVATE_KEY`) and the tracker configuration. Every integration — GitHub App auth, webhooks, Linear, voice, dashboard, Supervisor Decision API, provider keys — is optional; absence disables the feature and is reported once at startup, never a boot failure.
- **All-or-nothing credential groups.** A partially configured group (one dashboard credential without the other, or some but not all GitHub App credentials) fails at startup naming the missing members; a fully absent group is a supported setup.
- **Type validation.** Values that fail their declared type (for example `AIUR_OPENCODE_BRIDGE_PORT=banana`) abort the boot naming the variable and what was expected, instead of failing at first use hours later.
- **Secrets never leak.** Secrets render as an empty placeholder in `.env.example` and are excluded from error text and startup warnings. No real value from any `.env` file reaches the generated example, logs, or error output.
- **Dashboard credentials** (`AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD`) are values an operator chooses and types into a browser; see [Executor control center](/guide/executor-control-center) for choosing and setting them. Without them the dashboard refuses all requests (fails closed); the CLI and TUI are unaffected.

The generated `.env.example` groups variables under `## Required`, `## Optional - ...` (one section per integration), `## Runtime - launcher-managed`, and `## Development and debugging` headers, with a one-line purpose above each key and a terse right-hand "how to fetch" note aligned to a common column.

## Top-level

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `max_vertical_panes` | integer | 3 | Caps visible agent chat panes. |
| `pre_warmed_sessions` | integer | 3 | Number of opencode sessions booted early; 0 disables pre-warm. |
| `max_log_history_mb` | integer | 1000 | Caps persistent log history in MB. |
| `prompt_file` | string | nil | Per-repository Liquid prompt template. |
| `debug` | boolean | false | Enables file logging without the CLI debug flag. |
| `hooks_file` | file pointer | none | Sibling YAML file merged as the `hooks:` block. |
| `executor_takeover_first_alert_hours` | integer | 8 | First Executor takeover advisory threshold in hours; `0` disables. |
| `executor_takeover_continuous_alert_hours` | integer | 1 | Repeated takeover advisory cadence in hours after the first; `0` disables repeats. |

## executor takeover alerts

Aiur watches nonterminal tickets in the run scope and, once a ticket's
**convergence age** crosses a configurable threshold, raises an advisory
`needs_attention` alert visible in `aiurdev alerts --needs-attention` and the
watch actionable section. The alerts are advisory takeover prompts — they never
perform a takeover automatically.

- `executor_takeover_first_alert_hours` (default `8`) — a nonterminal ticket
  first raises the advisory once its convergence age reaches this value.
- `executor_takeover_continuous_alert_hours` (default `1`) — while the ticket
  stays nonterminal and unresolved, the advisory is repeated at most this often.
  A value of `0` disables repeats (first alert only); `0` on the first threshold
  disables the feature. Negative or non-integer values are rejected.

**Convergence age** is `now − min(first_observed_active_work_at,
open_pr_created_at)`:

- `first_observed_active_work_at` is persisted durably per ticket in daemon
  state, set once the first time the monitor observes the ticket as nonterminal
  and in scope. A worker restart, redispatch, `max_turns` recycle, or daemon
  restart never resets it.
- `open_pr_created_at` is the creation time of the ticket's open PR (a floor,
  so an already-open PR is never hidden by a freshly installed or restarted
  monitor).

The alert carries actionable evidence.

| Evidence | Detail |
| --- | --- |
| Identity | Ticket and PR. |
| Age | Elapsed convergence age. |
| Activity | Last material push, current live-owner state, and dispatch/restart count. |
| PR health | Base and merge freshness. |
| CI | Current state when available, for tickets already alerted. |

A ticket that becomes terminal or leaves the run scope resolves its active advisory and forgets its convergence state; a re-opened ticket starts a fresh episode.

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
| `tracker.github.daemon_core_limit_per_hour` | integer | 1000 | Hourly billable Core (REST) response ceiling for the daemon actor. A `304` is reconciled as free. When the daemon hits the ceiling, only its requests hold until the rolling hour rolls back under it. `0` disables. Re-derived down against the corrected Core volume after GraphQL commands stopped booking to Core (#2297). |
| `tracker.github.daemon_graphql_limit_per_hour` | integer | 3000 | Hourly billable GraphQL response ceiling for the daemon actor. `0` disables. Raised from 2000 because `gh pr view`/`gh issue view`/`gh search` are GraphQL on the wire and now book to the GraphQL window (#2297). |
| `tracker.github.daemon_search_limit_per_hour` | integer | 1000 | Hourly billable `search` response ceiling for the daemon actor. GitHub meters `/search/*` against a third pool (~30 req/min), so `gh search repos|code|commits|users` books there and gets its own pacing rather than folding into core (#2297). `0` disables. |
| `tracker.github.agent_core_limit_per_hour` | integer | 250 | Hourly billable Core (REST) response ceiling for each agent workspace. When one agent hits it, only that agent holds. `0` disables. Core volume is a small fraction of the measured ledger, so per-agent Core stays small. |
| `tracker.github.agent_graphql_limit_per_hour` | integer | 750 | Hourly billable GraphQL response ceiling for each agent workspace. `0` disables. Raised from 375: a single agent's normal loop (`pr view`/`issue view`/`pr checks`) crossed the old ceiling in a rolling hour and stalled it, because high-level GraphQL commands now book to the GraphQL window (#2297). |
| `tracker.github.agent_search_limit_per_hour` | integer | 250 | Hourly billable `search` response ceiling for each agent workspace. GitHub meters `/search/*` against a third pool (~30 req/min), so `gh search repos|code|commits|users` books there and gets its own pacing rather than folding into core (#2297). `0` disables. |
| `tracker.github.credentials` | array | `[]` | Additional GitHub credentials the daemon spreads read traffic across, so one exhausted budget does not stop the fleet. Empty — the default — means one credential resolved exactly as before. See [Credential pooling](/apis/github#credential-pooling). |
| `tracker.github.credentials.id` | string | required | Lowercase identifier naming this credential in `aiur github-usage` and `aiur github-cost`. Must be unique. |
| `tracker.github.credentials.kind` | string | `machine_user` | One of `app_installation`, `machine_user` or `human`. Set it to `human` for a real person's token so Aiur keeps writes off that identity. |
| `tracker.github.credentials.identity` | string | nil | The GitHub login this credential authenticates as. Reporting only, so a usage row names an account rather than a hash. |
| `tracker.github.credentials.token_env` | string | required except for `app_installation` | Environment variable holding the token. An `app_installation` credential mints its own and needs none. A variable that is not exported drops the credential from the pool rather than failing boot. |
| `tracker.github.credentials.writes` | boolean | `false` | Whether this credential may carry writes (comments, labels, merges, PR creation). A `human` credential cannot be set to `true`: GitHub attributes the write to that person and it breaks the agent-authors / human-reviews separation the merge policy depends on. |
| `tracker.github.credentials.enabled` | boolean | `true` | Set to `false` to keep a credential in the file but out of the pool, for a token being rotated or an account temporarily rate-limited. |
| `tracker.github.repo` | string | required for GitHub | GitHub owner/name used by Aiur. |
| `tracker.github.label_prefix` | string | `agent` | Prefixes lifecycle labels. |
| `tracker.github.bot_account` | string | nil | Login the **agents** publish as — the account that pushes branches, opens pull requests, and comments for a ticket. This is an identity, not the credential: the credential is `GITHUB_TOKEN`. `aiur init` defaults it to the token's login; prefer a dedicated bot account when operators also comment from a trusted CODEOWNER account. In a non-interactive or `--force` run the wizard applies the detected token login, or omits the key entirely when no login can be detected. Re-running `aiur init` preserves an existing value. When no `tracker.github.github_app.account` is set this login also stands in as the daemon's own identity for self-loop suppression. |
| `tracker.github.github_app.account` | string | nil | Optional. The GitHub App bot login (`<app-slug>[bot]`) the **daemon** writes as when App credentials are configured (see [GitHub](/apis/github#github-app-authentication)). Set it only when the daemon's identity differs from the agents': an App installation token can never write as `tracker.github.bot_account`, so one key naming both would make every agent-authorship check demand a login no agent holds. Leave it unset for a single-identity install — self-loop suppression, PR command handling and the CODEOWNERS self-include then fall back to `tracker.github.bot_account` exactly as before. Only the login lives here; the App credentials stay in `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID` and `GITHUB_APP_PRIVATE_KEY_PATH`. |
| `tracker.github.trusted_accounts` | array | `[]` | Usernames allowed to direct agents. |
| `tracker.github.allowed_users` | array | `[]` | GitHub logins allowed to use trusted operator paths. |
| `tracker.github.human_mergers` | array | `[]` | GitHub logins allowed to perform human merge actions. |
| `tracker.github.planning_root_limit` | integer | 100 | Maximum Build Order planning roots fetched in one cycle. |
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
| `polling.intervals` | map of class → integer | `%{}` | Per-class poll cadences in seconds. Each key names a poll class — `dispatch`, `ci`, `review`, `planning`, `firehose` — and overrides `interval_seconds` for that class only. A class with no entry falls back to `interval_seconds`, so an unset map keeps today's single-interval behaviour exactly. `0` means the class is on-demand — no timer, refreshed only when a consumer explicitly asks — which is the recommended value for `planning` and `firehose`. An unknown class key or a negative value is rejected. |
| `polling.idle_widen_factor` | float | 5.0 | Multiplier applied while no agents are actively running. Must be between 1.0 and 100.0. |
| `polling.usage_interval_seconds` | integer | 300 | Seconds between provider-meter probes. Values below 120 are rejected to avoid provider rate-limit degradation. |
| `polling.view_state_sweep_seconds` | integer | 900 | Seconds between runs of the view-state reconciliation sweep. It exists only to recover a webhook delivery that was lost, so it is a recovery bound rather than a refresh interval — a delivery that arrives updates the dashboard immediately and for free, and shortening this makes nothing fresher. The open-backlog and ad-hoc-overlay sources are event-sourced and not swept at all; the sweep reconciles the daemon-owned Build Order pack-status projection (which writes `status.json` on disk and stays on this cadence until it is moved to the event stream too) and runs the issue-family divergence watermark — a single bounded `updated_at`-ordered head page that keeps webhook loss detectable and re-converges a dropped delivery. |

Freshness thresholds follow this cadence. You do not set them separately.

- The **effective** interval is a class's interval after `idle_widen_factor`,
  `webhooks.poll_widen_factor` and GitHub's poll floors are applied.
- Since #2309 each poll loop resolves its interval by naming the class it
  serves, and `polling.intervals` lets those classes diverge. The classes:

  | Class | Polls | Why it gets its own cadence |
  | --- | --- | --- |
  | `dispatch` | open issues and `agent:*` labels (the dispatch trigger) | Cheap (conditional REST, usually `304`) and urgent. The default for every unlisted class and for un-named `PollCadence` reads. |
  | `ci` | check state on a pull request with work in flight | Expensive GraphQL and urgent, but only while a PR is actually in flight (the loop is demand-scoped). Keep `ci` at or below `dispatch`; a wide `ci` makes a stale CI read an agent-visible problem. |
  | `review` | comments and review threads | Expensive GraphQL, moderately urgent, and webhook-covered for comment *arrival* — the poll is a safety net, so minutes is defensible. |
  | `planning` | Build Order catalog, pack status, ad-hoc listings | The most expensive reads and the least urgent. Recommended value `0` (on-demand): the catalog's only consumers are web pages and it is demand-gated, so it needs no timer. |
  | `firehose` | repo events | Already self-regulating via GitHub's `X-Poll-Interval`; the class exists so status can show its configured cadence, not to change its loop. Recommended value `0` — stop deriving anything from the global interval. |

- The dashboard, the Units catalog and Build Order ticket history all judge
  staleness against the effective interval of the class they mean: the
  orchestrator snapshot readers derive from `dispatch`, Build Order catalog and
  ticket history from `planning`.
- Build Order's own refresh cadences follow the `planning` class, so an operator
  can run the expensive Build Order reads on demand while dispatch stays at 2.
  The catalog itself is event-sourced (#2325) and demand-gated (#2312): there
  is no recurring sweep — reads happen when a page opens or a degradation needs
  a re-list — and the `planning` cadence remains the base for its boot/mount/
  degraded reads and its staleness window. With `planning: 0` the class has no
  timer at all: a page mount or an explicit refresh is the only thing that
  reads it.
- So a change to an interval needs no matching threshold edit.
- `aiur status` prints the effective value and the live interval per class, for
  example:
  ```
  POLL idle backoff active: interval=1200s base=120s factor=5.0x
  POLL class intervals: ci=60s dispatch=120s firehose=0s planning=0s review=300s
  ```
  `0s` means the class is on-demand: no timer, refreshed only when a consumer
  asks.
- The idle widening only applies once the daemon has observed an idle cycle:
  a freshly restarted fleet starts at the base interval, and a live fleet with
  dispatchable tickets keeps the base interval so work is not left waiting
  behind a backed-off sweep (#2138).

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
| `worker.ssh_hosts` | array | `[]` | SSH hosts available for remote execution. Each server must allow `BASH_ENV`, `ENV`, `HOME`, and `ZDOTDIR` through OpenSSH `AcceptEnv`; Aiur neutralizes them before the account shell starts and fails closed if the server rejects them. |
| `worker.max_concurrent_agents_per_host` | integer or nil | nil | Per-host concurrent-agent cap. |

## agent

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `agent.priority` | array | `[]` | Ordered dispatch preference, as **routes** (`backend` or `backend:model`); see [Routes in `agent.priority`](#routes-in-agent-priority). Presence makes a backend dispatchable, the first available entry is the default, and limits advance to the next entry until recovery. A non-empty list replaces `agent.kind`, `agent.switch_model_on_ratelimit`, and `backend_configs.<b>.enabled`. |
| `agent.pricing_policy.avoid_peak_pricing` | boolean | `true` | Routes around peak-pricing windows through `agent.priority`; `false` follows the list exactly and never changes spend reporting. When the window cannot be determined, routing never moves work (it fails toward not rerouting). Inspect the current window and next boundary with `mix aiur.pricing_window`. |
| `agent.kind` | string | `codex` | Deprecated default backend; ignored when `agent.priority` is non-empty. |
| `agent.remote_control` | boolean | false | Opts RC-capable backends into remote control. |
| `agent.prior_work_continuation` | boolean | true | Lets a resumed ticket continue existing workspace work when policy permits. |
| `agent.max_dispatches_per_ticket` | integer | 0 | Per-ticket dispatch latch; 0 disables the latch. |
| `agent.max_concurrent_agents` | integer or nil | derived from host capacity | Global simultaneous-agent cap. When omitted, it derives from the measured host capacity: `schedulers + schedulers / 4` (e.g. 20 on a 16-core host), so the ceiling is calibrated to the box instead of a hard-coded count. Explicit config wins. The load envelope reduces effective concurrency below this ceiling under host pressure. |
| `agent.max_concurrent_builds` | integer | 2 | Caps local agent Mix verification; 0 deliberately disables the concurrency cap. When every build slot is busy or builds are queued, the dispatch gate defers new admissions (`build` capacity hold). |
| `agent.build_start_stagger_seconds` | integer | 0 | Minimum spacing between local Mix build starts; 0 disables pacing. |
| `agent.min_free_memory_mb` | integer or nil | nil | Linux `MemAvailable` floor shared by dispatch and the Mix build gate. |
| `agent.build_gate_max_hold_seconds` | integer | 3600 | Absolute wall-clock cap on how long one build-gate slot may be held. The lease holder releases the slot at the cap and the daemon raises a needs-attention alert naming the command; `0` disables the backstop. |
| `agent.build_gate_retain_seconds` | integer | 120 | Maximum post-command window the lease holder keeps a slot after the wrapped command exits, gated on a descendant still consuming CPU. The holder releases the moment the retained tree goes idle, so this bounds only a genuinely-busy descendant (a runaway build), not an adopted idle daemon; `0` disables the courtesy. |
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
| `agent.max_load_average` | float | 1.5 | Per-scheduler load ceiling. Above it, dispatch holds only when a short-window CPU sample also shows less than 60% reclaimable capacity (idle + niced CPU); null disables it. Until that sample exists — the first dispatch decision after the daemon starts has nothing to compare against — dispatch proceeds, and the next cycle holds if the measured window confirms the contention. |
| `agent.target_load_average` | float | 1.0 | Adaptive per-scheduler load target; null disables the adaptive envelope. |
| `agent.run_queue_threshold` | float or nil | nil | Per-scheduler runnable-process ceiling for the instantaneous run-queue dispatch gate; null disables it. When enabled, `procs_running` above `run_queue_threshold × schedulers` holds only when the same CPU sample shows less than 60% reclaimable capacity, catching real short bursts without treating niced work as contention (`run_queue` capacity hold). |
| `agent.load_ramp_step` | integer | 1 | Capacity increase while load is below the target. |
| `agent.load_cooldown_seconds` | integer | 60 | Minimum interval between adaptive capacity reductions. |
| `agent.synthetic_load_process_cap` | integer or nil | nil | Caps synthetic load processes; 0 disables the guard. |
| `agent.backend_configs` | map | `%{}` | Provider-specific configuration, including per-backend settings and credentials for OpenAI-compatible backends. A backend listed in `agent.priority` is enabled automatically. |
| `agent.rate_limit_primary` | string | default backend | Deprecated primary backend watched for automatic rate-limit recovery; derived from `agent.priority` when set. |
| `agent.max_turns_by_complexity` | map | `%{}` | Per-complexity turn caps. |
| `agent.mix_scheduler_cap` | integer | 4 | Caps schedulers in agent-launched Mix BEAMs. |
| `agent.saturation_log_enabled` | boolean | true | Records host and VM diagnostics when sustained load crosses the saturation threshold. |

### Routes in `agent.priority`

Each entry is a **route**, not just a backend name. A route uses the same
grammar `agent.routing` has always used:

```
<backend>[:<model>[:<effort>]][+remote]
```

- `claude`: the backend's own direct connection, exactly as before.
- `openrouter:anthropic/claude-sonnet-5`: that model reached through OpenRouter.

A colon-free entry means what it has always meant, so **existing configs need
no change**.

```yaml
agent:
  priority:
    - claude                                # Anthropic direct
    - openrouter:anthropic/claude-sonnet-5  # same model, billed by OpenRouter
    - codex                                 # OpenAI direct
    - openrouter:moonshotai/kimi-k2.7-code  # no direct Moonshot key: OpenRouter only

  backend_configs:
    openrouter:
      provider:
        order: [Anthropic, "Together AI"]
        allow_fallbacks: true
        ignore: [Azure]
        sort: price

  pricing_policy:
    avoid_peak_pricing: true
```

**A model reachable two ways may appear twice, and the order is the fallback
order.** Duplicate *routes* are rejected; duplicate backends are not.

| Model name | Behavior |
| --- | --- |
| Full provider slug | Canonical form and cost-reporting key. |
| Short family alias | Resolves to the newest matching concrete slug before the request, so normal pricing applies. |
| Alias claimed by multiple vendors | Rejected during config load. |
| Aggregator ID beginning with `~` | Rejected because its target can change during a run. |

**OpenRouter needs an explicit model.** It fronts a catalog rather than a
product, so a bare `openrouter` entry is a config error.

**An untagged model never falls back to OpenRouter implicitly.** Bare `claude`
means direct-only, always. Routing through OpenRouter is something you write.

#### What happens when a route fails

| Cause | Behaviour |
| --- | --- |
| **No API key configured** | The route is skipped at selection time and the next entry is used. Named once at startup in the log, not per claim. If *every* entry lacks its key, aiur fails loudly rather than dispatching nothing. |
| **Usage or rate limit (429)** | Advances to the next entry and records the backend in `model-usage.json` with its reset time. Self-healing. |
| **Transient error (5xx, timeout, malformed response)** | Retries, then advances **for that claim only**, and raises an operator attention. Deliberately *not* written to `model-usage.json`: that file means "rate-limited until `reset_at`", and recording an outage there would make the outage indistinguishable from a quota event. |
| **Auth rejected (401)** | Does **not** advance. Hard failure plus an attention. A key that is present and wrong is a config error, and falling through would move spend silently onto another route while the broken credential stayed hidden. |

#### `agent.backend_configs.<backend>`

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `agent.backend_configs.<backend>.enabled` | boolean | backend registry default | Explicitly enables or disables dispatch for the backend. `agent.priority` takes precedence by enabling every backend it names. |
| `agent.backend_configs.<backend>.command` | string | backend registry command | Overrides the backend command used for model discovery and setup where supported. |
| `agent.backend_configs.<backend>.model` | string or nil | nil | Selects the backend's default model where the backend accepts a configured model. |
| `agent.backend_configs.<backend>.default_model` | string or nil | backend registry value | Overrides the registry fallback model for an OpenAI-compatible backend; `model` takes precedence. |
| `agent.backend_configs.<backend>.base_url` | URL string | backend registry value | Overrides the registry endpoint for an OpenAI-compatible backend. |
| `agent.backend_configs.<backend>.api_key_env` | string | backend registry value | Names the environment variable containing the backend API key. |
| `agent.backend_configs.<backend>.management_api_key_env` | string or nil | backend registry value | Names the environment variable containing a provider's usage-management API key. |
| `agent.backend_configs.<backend>.transport` | string | backend registry value | Overrides the OpenAI-compatible transport with `chat_completions` or `responses`. |
| `agent.backend_configs.<backend>.balance_baseline` | number or nil | nil | Seeds prepaid-balance usage tracking for backends that expose a balance API. |
| `agent.backend_configs.<backend>.quirks.reasoning_content_replay` | boolean | backend registry value | Replays reasoning content when the backend requires it in later requests. |
| `agent.backend_configs.<backend>.quirks.text_tool_fallback` | boolean | backend registry value | Parses text-encoded tool calls when the backend does not return structured calls. |
| `agent.backend_configs.<backend>.quirks.openrouter_metadata` | boolean | backend registry value | Enables OpenRouter endpoint metadata used for billing attribution. |
| `agent.backend_configs.<backend>.quirks.local_concurrency_limit` | boolean | backend registry value | Applies aiur's local concurrency slot around backend requests. |

#### `agent.backend_configs.openrouter`

These settings control the OpenRouter *transport*; selection lives entirely in `agent.priority`.

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `agent.backend_configs.openrouter.provider.order` | array of strings or nil | omitted | Preferred upstream providers, most preferred first. |
| `agent.backend_configs.openrouter.provider.ignore` | array of strings or nil | omitted | Upstream providers to exclude. |
| `agent.backend_configs.openrouter.provider.allow_fallbacks` | boolean or nil | omitted | Whether OpenRouter may cross to another upstream within one request. |
| `agent.backend_configs.openrouter.provider.sort` | string or nil | omitted | `price`, `throughput`, or `latency`. |

#### Cost attribution

| Cost case | Attribution |
| --- | --- |
| `openrouter:anthropic/claude-sonnet-5` | Uses OpenRouter's price row because OpenRouter bills the request, even when Anthropic serves it upstream. |
| Same model through direct and OpenRouter routes | Keeps separate identities and may carry different rates. |

Local Codex turns use Aiur's shared build admission.

| Build-gate behavior | Detail |
| --- | --- |
| Admission failure | Mix does not run and the ticket reports status `125`. Repair the reported metadata or lock directory, `flock`, or `python3` dependency, then restart or re-dispatch the agent. |
| `BUILD GATE DEGRADED` | Stop the old fleet, confirm no old Mix verification remains, then clear only the legacy records named in the message. |
| `BUILD GATE HOLDER` / `BUILD GATE QUEUED` | `aiur status` names every held lease: `slot=`, the owning `pid`, the quoted `command`, and how long it has been `held` (or `waiting` while queued). This tells a correctly-busy gate apart from one pinned by a leaked or dead process. A slot whose command process group is gone renders as `held without a command` (and its HOLDER line gains `(command gone)`), so `BUILD GATE n/n active` never claims work is happening when nothing is. |
| Hold-timeout backstop | A slot held past `agent.build_gate_max_hold_seconds` (default 1h) is released by the lease holder itself, which logs and leaves a durable `slot-N.hold-timeout` marker. `aiur status` prints those as `BUILD GATE TIMEOUT` lines, and the daemon raises a needs-attention alert naming the command — the same backstop bounds both a leaked holder waiting on reparented daemons and a `--trace` run that monopolises a slot. |
| Post-command retain | After the wrapped command exits, the holder keeps the slot only while a descendant is still consuming CPU (`agent.build_gate_retain_seconds`, default 120s, is the ceiling for that busy descendant). A descendant tree that goes idle for one second is treated as an adopted session daemon (`dbus-daemon`, `gnome-keyring-daemon`), so the slot is released immediately and nothing is signalled — the keyring daemon holds the fleet's GitHub credential. The effective retain is observable in `aiur status` (`retain_seconds=`) and in the `lease_retained` gate log line. |
| Dead holder | A lease whose holder has exited is released automatically: Linux releases the flock with the process, and the PID fallback reclaims a slot whose recorded owner and process group are gone. A legitimately long-running build with a live holder keeps its lease; only the absolute max-hold backstop reaps by elapsed time. |
| Explicit opt-out | Set `agent.max_concurrent_builds: 0`, set `agent.build_start_stagger_seconds: 0`, and omit `agent.min_free_memory_mb`. This removes every build safeguard. |

Build admission covers direct `mix compile` / `mix test`, `mix do` compounds using `+`
or legacy comma separators, `elixir -S mix`, and `mise exec` / `mise x` commands after
`--` or in a simple `-c` / `--command` string. One compound or nested wrapper chain
holds one live-token lease.

Malformed compounds and command strings that could hide a Mix build fail with status
`125`. This is a cooperative PATH/shell boundary: aliases of Aiur's wrappers are
canonicalized, but deliberately invoking a separate real executable by absolute,
relative, or symlinked path bypasses the entrypoint and is not admitted.

## Host-pressure fleet admission

Fleet admission uses total host pressure instead of a hard-coded process count, and disabled or unreadable signals fail open.

| Signal | Admission behavior |
| --- | --- |
| CPU load and adaptive AIMD envelope | `agent.max_load_average`, `agent.target_load_average`, `agent.load_ramp_step`, and `agent.load_cooldown_seconds` reduce and re-ramp capacity around per-scheduler targets. |
| Run queue | `agent.run_queue_threshold` reacts to `procs_running` spikes before the one-minute load average catches up. |
| CPU corroboration | High load or runnable counts hold dispatch only when consecutive CPU samples show less than 60% reclaimable capacity; idle and niced CPU count as reclaimable. Without a measurable window there is no hold, so every `capacity_hold` for `load` or `run_queue` carries the reclaimable-CPU measurement behind it. |
| Memory, file descriptors, build pressure, and provider limits | Defer new dispatch while their configured reserve or limit is exhausted. |
| Recovery | Gates reopen when pressure clears, and AIMD re-ramps within its cooldown window. |

| Hold signal | Where it appears |
| --- | --- |
| Idle rows | `backing off` |
| Dashboard and status | `capacity_hold` with the measured signal, threshold, and corroborating reclaimable-CPU measurement |
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
| `agent.codex.turn_sandbox_policy` | map or nil | nil | Explicit per-turn sandbox policy. For local `workspaceWrite`, `writableRoots` contains optional daemon-host extras; every entry must already exist and be writable. Aiur derives the current issue workspace and enabled shared GitHub budget root. Configured extras are not forwarded to SSH workers. |
| `agent.codex.read_timeout_ms` | integer | 5000 | Codex app-server read timeout. |
| `agent.codex.thrash_max_per_window` | integer | 6 | Rapid restart limit per window. |
| `agent.codex.thrash_window_seconds` | integer | 60 | Thrash-counting sliding window. |

## Model discovery

Aiur ships a curated model list per backend (`Aiur.CodingAgent.backends/0`). Providers
release models faster than that list is edited, so for OpenAI-compatible backends aiur
also asks the provider's own catalogue endpoint which models it currently serves, and
caches the answer.

Discovery **extends** the curated list without replacing registry-owned effort vocabularies,
capabilities, family aliases, presentation, or `aiur init` choices, and curated metadata wins
when an ID collides.

| Backend | Endpoint | Credential | Returns |
| --- | --- | --- | --- |
| `openrouter` | `GET https://openrouter.ai/api/v1/models` | none required (sent when `OPENROUTER_API_KEY` is set, so the request is attributed to your account) | identifiers, context window, **and pricing** |
| `deepseek` | `GET https://api.deepseek.com/models` | `DEEPSEEK_API_KEY` | identifiers only |
| `kimi` | `GET https://api.moonshot.ai/v1/models` | `MOONSHOT_API_KEY` | identifiers only |

`codex` and `claude` are not listed: they answer `model/list` over their own CLI
transport, which `aiur init` already asks. Anthropic's `GET /v1/models` (`x-api-key`
plus `anthropic-version`) has an adapter for operators who point an OpenAI-compatible
backend straight at it; it returns identifiers and display names, no pricing.

### Cache, TTL, and cold start

| Property | Value |
| --- | --- |
| Location | `model-catalog.json`, beside the active workflow config and `model-usage.json` |
| TTL | 24 hours |
| Refresh trigger | Lazy and backgrounded; reading the usable model set schedules a refresh only when the cache is older than the TTL. |
| Cold offline start | the discovered set is empty and aiur uses exactly the curated list, i.e. it behaves as it did before discovery existed |
| Corrupt cache | treated as absent; falls back to the curated list |

Writes are atomic (temp file plus rename) and a concurrent refresh is a no-op rather
than a duplicate request.

**Config validation never makes a network call.** Validation reads the cache and
nothing else. An absent or stale cache means "cannot verify", and a model aiur cannot
verify is **accepted**, never rejected.

### Identifiers aiur refuses

Two classes of catalogue id are rejected at ingest, with the reason recorded in the
cache under `rejected`:

- **`reserved_routing_separator`**: an id containing `:`, such as
  `moonshotai/kimi-k2.7-code:batch`. Aiur routing values are `backend:model:effort`, so
  `openrouter:moonshotai/kimi-k2.7-code:batch` would parse `batch` as a reasoning
  effort. Pin such a variant only if and when aiur gains a way to escape the separator.
- **`unstable_identifier_prefix`**: an id starting with `~`, such as
  `~moonshotai/kimi-latest`, which OpenRouter uses for a non-canonical pointer rather
  than an addressable model.

### Pricing is advisory

| Pricing rule | Behavior |
| --- | --- |
| Fetched OpenRouter price | Recorded in the cache for comparison but never written into the curated price table. |
| Curated row | Always wins attribution. |
| Difference above 5% | Logs both numbers as price drift without letting vendor data rewrite reported spend. |

A discovered model with **no** curated price row is usable but visibly unpriced: its
usage reports unknown cost with an `unknown_price_model` coverage reason. It is never
costed at zero. A refresh logs how many discovered models are unpriced.

### Per-backend opt-out

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `agent.backend_configs.<backend>.model_discovery` | boolean | true | Set `false` to stop aiur asking this backend's catalogue endpoint. The curated list keeps working. |

```yaml
agent:
  backend_configs:
    openrouter:
      model_discovery: false
```

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

`poll_seconds: 0` disables periodic refreshes, not dispatch-time freshness checks.

When a prewarm build or freshness probe holds fleet dispatch, an independent idle
watchdog releases the gate for cold-clone fallback once the hold has been stalled
for 10 minutes.

"Stalled" means the hold's worker process is dead with no completion signal in
flight. A build that is still progressing — however slow a cold `deps` +
`compile` + `dialyzer` run may be — is never killed by the watchdog.

The `system.dispatch.prewarm_blocked` alert is not raised for a routine refresh:
a freshness probe that self-clears in seconds holds dispatch too briefly to
matter to an operator.

The alert fires only once a hold has persisted past the routine bound: a probe
that fails or exceeds its own timeout, a build that genuinely holds the fleet,
or a stalled hold the watchdog releases. Its `.resolved` fires when the gate
clears.

## pr_watch

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `pr_watch.enabled` | boolean | false | Enables trusted PR comment watching. |
| `pr_watch.watch_label` | string | `watch` | Label suffix enrolling a PR for watching. |
| `pr_watch.command_prefix` | string | `/aiur` | One-off trusted comment command prefix. |

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

A PR whose head only moved via merges of the base branch (own contribution
unchanged) is NOT re-queued; it raises `system.pr_health.rework_merge_only` so
the merge-only state is visible distinctly from genuine rework.

A re-queue that the thread-clearance gate refuses (the reworked PR still has
unresolved review threads — the normal state of a rework ticket) raises
`system.pr_health.rework_requeue_failed`; the head is not throttled on a failed
write, so the re-queue retries on the next tick instead of silently stranding
the ticket in rework.

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `pr_health.enabled` | boolean | false | Enables the PR-health scan and the rework re-queue. |
| `pr_health.interval_seconds` | integer | 1800 | How often the scan lists open PRs. |
| `pr_health.stale_hours` | integer | 24 | A non-draft PR older than this with no review is flagged. |

## events

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `events.block_state_debounce_seconds` | integer | 10 | Debounces blocked/unblocked transitions. |
| `events.custom_events_per_turn_max` | integer | 5 | Caps custom events per turn. |
| `events.codeowners_refresh_seconds` | integer | 3600 | CODEOWNERS refresh interval. |

## upgrade

The `aiur run` upgrade-version notice is optional and opt-out: it caches with a
TTL (the registry is contacted at most once a day), fails open and silent when
unreachable, never runs under `aiurdev`, and is channel-aware — a `nightly` or
`next` user is never offered a lower `latest`.

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `upgrade.check_enabled` | boolean | true | Enables the `aiur run` version notice and its registry check. Set false to suppress the check entirely (zero outbound calls). |

`AIUR_UPGRADE_CHECK_DISABLED` (and the legacy `AIUR_NO_UPDATE_NOTIFIER`) are the
environment-variable equivalents; the check also stays silent in CI runs.

## alerts

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `alerts.enabled` | boolean | true | Master alert-sound switch. |
| `alerts.use_os_default_sounds` | boolean | false | Uses built-in OS sounds by category. |
| `alerts.sound_dir` | string path or nil | nil | Directory for custom sound files. |
| `alerts.alerts_file` | string path or nil | bundled alerts file | Topic-to-sound YAML map. |

## elevenlabs

Both capture clients stream audio to Aiur, and Aiur calls ElevenLabs with the credential below; interactive conversation also streams speech audio back to the browser. This is the only place the credential is configured, and neither the sidecar nor the browser holds it.

This optional section backs Stream Deck voice input, Dashboard dictation, and interactive spoken replies; omitting it uses the defaults below.

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `elevenlabs.api_key` | string or nil | nil | ElevenLabs credential. Accepts a literal value or a `$ELEVENLABS_API_KEY` environment reference. Speech input needs Speech to Text permission; spoken replies also need Text to Speech permission. |
| `elevenlabs.language_code` | string | `eng` | ISO-639-3 transcription language. ElevenLabs uses `eng` for English. |
| `elevenlabs.voice_id` | string or nil | nil | Stock or owned ElevenLabs voice used for Dashboard interactive conversation replies. Find the identifier in **My Voices**; Aiur does not clone or manage voices. |

`ELEVENLABS_API_KEY` is the environment variable for the credential. An explicit `elevenlabs.api_key` value wins; when the key is absent, or is the `$ELEVENLABS_API_KEY` reference, the variable supplies it. An environment variable set to the empty string resolves to no key.

The key is a secret. Keep it in `.env` and leave the `$ELEVENLABS_API_KEY` reference in the config file rather than pasting the value there. Aiur never logs the key, and the daemon scrubs every `*_API_KEY` variable, `ELEVENLABS_API_KEY` included, from agent process environments, local and SSH-launched alike, so no coding agent inherits it.

Configuring the key also adds an ElevenLabs meter to the Dashboard Units page, beside the GitHub API meter. It reads the account credit quota and next-invoice amount due from `GET /v1/user/subscription`; with no key configured the meter is absent entirely. See [API meters](/concepts/units#api-meters) for what each figure does and does not measure.

## observability

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `observability.dashboard_enabled` | boolean | true | Reserved compatibility setting; use the launch-time `--no-dashboard` flag to suppress the listener in foreground or background mode. |
| `observability.dashboard_writable` | boolean | true | Enables dashboard write paths. A dashboard bound beyond loopback refuses to start without both dashboard basic-auth environment variables; a loopback listener binds without them and fails closed (see below). |
| `observability.refresh_ms` | integer | 1000 | Dashboard data refresh interval. |
| `observability.render_interval_ms` | integer | 16 | Minimum render interval. |
| `observability.telemetry_enabled` | boolean | true | Records run telemetry for analytics. |
| `observability.telemetry_retention_max_bytes` | integer | 67108864 | Maximum retained telemetry bytes. |
| `observability.telemetry_retention_max_age_days` | integer | 30 | Maximum retained telemetry age. |
| `observability.telemetry_retention_prune_interval_bytes` | integer or nil | nil | Bytes between retention-prune checks. |

`dashboard_writable` is an authorization gate, not an authentication mechanism. Every usable dashboard requires `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`.

A loopback listener — writable or read-only — may bind without them, but its authentication plug fails closed and refuses every dashboard request until both credentials are set. A dashboard bound beyond loopback refuses to start without both credentials.

The supervising-Executor Decision API uses the separate `AIUR_SUPERVISOR_TOKEN` bearer credential. Generate it with `openssl rand -base64 32`, then put `AIUR_SUPERVISOR_TOKEN=<generated-token>` in `~/.aiur/.env` (global) or the repository `.env` (project-local).

An exported value wins, followed by the global file and then the repository file. The value must be at least 32 bytes, bearer-safe, and free of surrounding whitespace. A present non-empty invalid value aborts startup; an absent or empty value leaves the API disabled.

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
| `build_order.ticket_detail_freshness_ms` | integer | derived (¼ poll interval, min 5000) | Freshness window for ticket detail. |
| `build_order.ticket_detail_max_entries` | integer | 32 | Maximum cached ticket-detail entries. |
| `build_order.ticket_detail_max_description_bytes` | integer | 16384 | Maximum cached ticket-description size. |
| `build_order.ticket_history_limit` | integer | 50 | Maximum ticket history records per view. |
| `build_order.ticket_history_max_identities` | integer | 100 | Maximum distinct ticket identities retained in history. |
| `build_order.ticket_history_stale_after_ms` | integer | 60000 | Minimum age after which ticket history is stale. It is a floor, not the final window: the effective window is always at least two poll intervals wide, so a value below the poll cadence does not mark correct data stale. |
| `build_order.graph_catalog_refresh_ms` | integer | derived (1× effective poll interval) | Base cadence for the Build Order catalog's reads (boot, a viewer's mount, a degraded re-list) and the window after which a selected root is displayed as ageing. The catalog is event-sourced (#2325) and demand-gated (#2312): it is maintained from the resource store's change stream, so this is not a recurring poll, and no page open means no read. |
| `build_order.graph_catalog_labels_refresh_ms` | integer | derived (5× effective poll interval, min 600000) | Cadence for the labelled catalog read that resolves epic and wave counts on a boot/mount/degraded read; the event-sourced catalog resolves those counts from the store instead. |
| `build_order.graph_refresh_timeout_ms` | integer | 30000 | Maximum graph-refresh request duration. |
| `build_order.graph_max_selected_roots` | integer | 32 | Maximum selected Build Order roots. |
| `build_order.graph_max_inflight` | integer | 4 | Maximum concurrent graph refreshes. |

### Two removed keys

`build_order.graph_selected_refresh_ms` and `build_order.graph_demand_refresh_ms`
no longer exist. They were the two settings by which *viewing* bought GitHub
reads: the demand cadence fired when an operator selected a root, and the
selected cadence repeated for as long as the page stayed open.

No value makes that correct, because it makes API cost track how many people are
looking rather than what has changed. They were removed rather than retuned.

A selected root is now read by the daemon's own catalog reconciliation, and by
nothing else. Each catalog update carries a per-root change marker — the root's
identity, member count and update time, plus a digest of its members' states — and
a watched root whose marker moved is re-read once, as is a watched root that has
never been read.

Selecting a root and holding it open consume zero GitHub reads.

The **catalog** itself is different: it is the most expensive single query in the
system, and since #2312 it is demand-gated on an open Build Order page. Opening
`/build-orders` renders the stored snapshot immediately (with its age), then buys
one refresh on mount.

While any Build Order page stays open the catalog reconciles on the cadence
below; closing the last page stops it entirely, so a headless run — the normal
case — buys none of it.

`Aiur.BuildOrder.GraphProjection.refresh/2` is the explicit "read this now" path.
It exists so that removing the viewer cadence does not also remove an operator's
ability to demand a read, but **nothing calls it yet** — an operator-facing
refresh control is its intended consumer.

A configuration that still sets either key keeps loading unchanged: unknown keys
are ignored rather than rejected, so an upgrade gets the new behaviour instead of
a boot failure.

### Derived Build Order cadences

Three of these keys have no fixed default. They are derived from the poll
interval, and setting any of them explicitly overrides the derivation.

Build Order displays state that the tracker produces, so it cannot be fresher
than the tracker's own cycle. Refreshing faster only re-reads a graph that cannot
have moved.

The previous fixed defaults were chosen when the tracker polled every 5 seconds,
and did not move when the tracker changed to 120 seconds. Deriving them is what
stops that recurring.

Since #2325 the Build Order **catalog is event-sourced**: it is maintained from
`Aiur.GitHub.ResourceStore` change events, so there is no recurring catalog poll
at all — a root's membership and a blocked-by edge reach the page the moment the
delivery deposits them.

What remains on a cadence is the boot fill (one GraphQL read per daemon start),
the degraded re-read, and the selected-root reads those changes trigger; the two
graph keys below size those and the staleness window that follows, and they
follow the *effective* interval: the one the daemon actually scheduled.

- It is not `polling.interval_seconds` alone. It includes
  `polling.idle_widen_factor` and `webhooks.poll_widen_factor`.
- It is the value `aiur status` reports as `interval=`.
- So an idle fleet widens the catalog's reads and the staleness window exactly
  as it widens the tracker, and a fleet that picks up work narrows both back
  together.
- The widening matters only while a page is open: the catalog is event-sourced
  (#2325) and demand-gated (#2312), so with no Build Order page open it neither
  polls nor reads — it costs nothing rather than merely running slowly.

`ticket_detail_freshness_ms` follows the **base** interval instead. It is a
staleness window for the ticket-detail drawer, read once when the daemon starts
and never re-derived, so tying it to a cadence that moves would freeze it at
whatever the cadence was at boot.

Each derivation, and the values it produces at a 120s base interval:

| Key | Derivation | Busy fleet | Idle, polling repo | Idle, webhook-backed |
| --- | --- | --- | --- | --- |
| `graph_catalog_refresh_ms` | 1× effective interval, ceiling 3600000 | 120000 | 600000 | 1200000 |
| `graph_catalog_labels_refresh_ms` | 5× effective interval, floor 600000, ceiling 3600000, never below `graph_catalog_refresh_ms` | 600000 | 3000000 | 3600000 |
| `ticket_detail_freshness_ms` | ¼ base interval, floor 5000, ceiling 300000 | 30000 | 30000 | 30000 |

The effective interval at idle is 600s for a repository Aiur polls, and 1200s
once that repository is a proven webhook source (`webhooks.poll_widen_factor`
multiplies again). The labelled catalog read reaches its 3600000 ceiling in that
last column.

`graph_catalog_labels_refresh_ms` covers the 26-point labelled variant used by
the boot fill and a degraded re-read, so it is the slowest of the three, and it
can never fall below the catalog cadence it rides on — a labels read that
outran the catalog read would make every boot or degraded re-read buy the
expensive query.

`ticket_detail_freshness_ms` is not a cadence: nothing fires on it. It is the
staleness a ticket-detail reader accepts from the shared store before
revalidating, and it is allowed to be tighter than the graph cadences because it
is the only one of the three backed by a REST read — so the only one whose
refresh can be a free `304` rather than a paid query.

### What these cadences cost

GitHub's GraphQL API sends no `ETag`, no `Last-Modified` and no `Cache-Control`,
and every query is a `POST`. There is no conditional request to make, so no
GraphQL read below can ever return `304`, however it is written.

What that leaves is **how often a query runs**, which is where almost all of the
cost is.

GitHub's point cost is `round(connection_requests / 100)`, with a minimum of one
point. Anything below roughly 150 connection requests therefore costs exactly one
point, however much it asks for.

Size is not free above that threshold, but the lever is small: measured, a
54-member Build Order root costs 3 points at the shipped 100-per-page and 2 at
54-per-page. Running a query less often is worth far more than making it leaner.

Measured against `aiur-team/aiur` with GitHub's own `rateLimit { cost }`:

| Read | Protocol | Cost | Revalidation |
| --- | --- | --- | --- |
| `AiurBuildOrderCatalog` (cheap) | GraphQL | 1 point/page | Not possible |
| `AiurBuildOrderCatalog` (labelled) | GraphQL | 26 points/page | Not possible |
| `AiurBuildOrderSelectedRoot` (54 members) | GraphQL | 3 points/page, per selected root | Not possible |
| `AiurLinkedPullRequests` | GraphQL | 1 point | Not possible |
| `GET /repos/{owner}/{repo}/issues/{number}` | REST | 1 REST request | **`304`, which costs no primary rate limit** |

## Resolution & validation notes

- An unset or blank `prompt_file` falls back to the built-in default prompt; a configured unreadable path fails startup.
- A legacy top-level `linear:` section is merged into `tracker.linear`.
- Only `$VAR` environment references resolve; legacy `env:NAME` values remain literal.
- `polling.interval_ms` is rejected by the loader; use `interval_seconds`.

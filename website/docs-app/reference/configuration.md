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

### Choosing a poll interval

Polling spends GitHub GraphQL points at a rate inversely proportional to the
interval, and that spend is a fixed cost. It does not depend on how many agents
are running. Against GitHub's 5,000 point/hour budget:

| `interval_seconds` | Approximate poll spend | Worst-case wake latency |
| --- | --- | --- |
| 30 | ~5,800 points/hour | 30s |
| 60 | ~2,900 points/hour | 60s |
| 120 | ~1,450 points/hour | 2m |
| 300 | ~580 points/hour | 5m |

At 30 seconds the poll loop alone can exhaust the hourly budget before a single
agent makes a request, which is why the default is 120. Tightening it below 60
is only safe on a small fleet.

The figures above are what each interval costs if it is actually applied. GitHub
also sends an `X-Poll-Interval` header on the repo-events endpoint, 60 seconds
by default, and Aiur treats it as a floor. The interval actually used is the
wider of the two, so setting `interval_seconds` below 60 generally does not
speed polling up, while setting it above 60 does slow polling down.

Widening past 120 seconds is the flat part of the curve: each further step
saves less quota than the last while the wake latency grows proportionally.
Aiur's poll is state-based: it reads current issue labels and pull request
state rather than replaying an event log. A longer interval therefore delays a
wake but does not lose one. The exception is comment-driven wakes, where a comment
posted and answered between two polls is not distinguishable from no comment.

## webhooks

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `webhooks.repos` | list of `owner/name` | `[]` | Repos expected to deliver webhooks. A hint only. A listed repo keeps polling at full rate until it actually delivers. |
| `webhooks.silence_threshold_seconds` | integer | 900 | How long a proven repo may go without a delivery before it degrades back to full polling and raises a needs-attention alert. |
| `webhooks.sweep_interval_seconds` | integer | 60 | How often proven repos are checked for silence. |
| `webhooks.poll_widen_factor` | float | 2.0 | Multiplier applied to `polling.interval_seconds` for repos proven webhook-backed. Values below 1.0 are rejected. |

### How widening interacts with polling

Webhooks are the fast path; polling is not removed, it is demoted to a
reconciliation sweep. The widen factor is what demotes it, and it applies to one
repo at a time based on that repo's observed state:

| Repo state | Interval used |
| --- | --- |
| Never configured for webhooks | `interval_seconds` |
| Configured but has never delivered | `interval_seconds` |
| Proven, has delivered at least once | `interval_seconds × poll_widen_factor` |
| Proven, then silent past the threshold | `interval_seconds` |

Only an observed, signature-verified delivery promotes a repo to the widened
interval. Configuration alone never does, because configuration says a webhook is
*expected* and only a delivery proves the App install, the secret, and the ingress
all work.

The last row is the safety property worth stating on its own: when deliveries
stop, the silence sweep degrades that repo, the alert names it, and the next poll
tick is computed at the tighter interval automatically. There is no operator
action and no separate restore path. A fleet that goes blind polls at full rate
while it is blind. A delivery arriving later restores webhook mode on its own.

`X-Poll-Interval` and connectivity backoffs remain floors on top of all of this:
the tick actually used is the widest of the widened interval, GitHub's floor, and
any active backoff.

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
| `agent.priority` | array | `[]` | Ordered dispatch preference, as **routes** (`backend` or `backend:model`) — see [Routes in `agent.priority`](#routes-in-agent-priority). Presence in the array makes a backend dispatchable; the first available entry is the default backend; and when an entry hits a token or usage limit aiur falls back to the next one in the list, returning to an earlier one once it recovers. When non-empty it replaces `agent.kind`, `agent.switch_model_on_ratelimit`, and the `backend_configs.<b>.enabled` opt-in. |
| `agent.pricing_policy.avoid_peak_pricing` | boolean | `true` | Whether dispatch routes away from a provider's peak-pricing window, falling through to the next `agent.priority` entry. `false` means ignore pricing windows entirely and use `agent.priority` exactly as written — it never changes how spend is *reported*. Shape only today; the behaviour lands with time-of-day routing. |
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

### Routes in `agent.priority`

Each entry is a **route**, not just a backend name. A route uses the same
grammar `agent.routing` has always used:

```
<backend>[:<model>[:<effort>]][+remote]
```

- `claude` — the backend's own direct connection, exactly as before.
- `openrouter:anthropic/claude-sonnet-5` — that model reached through OpenRouter.

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

**Model names.** The canonical form is the provider's full slug, which is also
the key cost reporting uses. A short family alias works too — `openrouter:claude`
resolves to the newest `anthropic/claude-*` — and is widened to the concrete
slug before the request is sent, so aliased calls are priced normally. An alias
claimed by more than one vendor is rejected at config load rather than resolved
by coin flip. Aggregator ids beginning with `~` are rejected: they are floating
pointers whose target can change under a running fleet.

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

#### `backend_configs.openrouter`

Settings for the OpenRouter *transport*. Nothing here selects anything —
selection lives entirely in `agent.priority`.

| Key | Type | Controls |
| --- | --- | --- |
| `backend_configs.openrouter.provider.order` | array of strings | Preferred upstream providers, most preferred first. |
| `backend_configs.openrouter.provider.ignore` | array of strings | Upstream providers to exclude. |
| `backend_configs.openrouter.provider.allow_fallbacks` | boolean | Whether OpenRouter may cross to another upstream within one request. |
| `backend_configs.openrouter.provider.sort` | string | `price`, `throughput`, or `latency`. |

#### Cost attribution

Spend is priced by the **route**, never by whichever upstream ended up serving
the request. A call through `openrouter:anthropic/claude-sonnet-5` prices
against OpenRouter's rows for that slug even when the selected upstream was
Anthropic, because OpenRouter is who bills it. Direct and via-OpenRouter routes
to the same model are separate identities and may legitimately carry different
rates.

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

## Model discovery

Aiur ships a curated model list per backend (`Aiur.CodingAgent.backends/0`). Providers
release models faster than that list is edited, so for OpenAI-compatible backends aiur
also asks the provider's own catalogue endpoint which models it currently serves, and
caches the answer.

Discovery **extends** the curated list; it never replaces it. Reasoning-effort
vocabularies, capability flags, derived family aliases, presentation, and the models
`aiur init` offers stay registry-owned, and where a discovered id collides with a
curated one the curated metadata wins.

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
| Refresh trigger | lazy and backgrounded — reading the usable model set (e.g. when an agent session starts) schedules a refresh only if the cache is older than the TTL |
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

- **`reserved_routing_separator`** — an id containing `:`, such as
  `moonshotai/kimi-k2.7-code:batch`. Aiur routing values are `backend:model:effort`, so
  `openrouter:moonshotai/kimi-k2.7-code:batch` would parse `batch` as a reasoning
  effort. Pin such a variant only if and when aiur gains a way to escape the separator.
- **`unstable_identifier_prefix`** — an id starting with `~`, such as
  `~moonshotai/kimi-latest`, which OpenRouter uses for a non-canonical pointer rather
  than an addressable model.

### Pricing is advisory

OpenRouter is the only catalogue that quotes prices. Aiur records those numbers in the
cache and compares them to the curated price table, and stops there. Fetched prices are
**never** written into the price table, and a curated row always wins. A disagreement
larger than 5% logs a price-drift warning naming both numbers, which turns a stale
curated row (the failure mode where output spend is under-reported) into something you
can see — without letting a vendor feed silently rewrite what aiur reports having spent.

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

Optional. Backs Stream Deck voice input: the device records dictation and streams the audio to Aiur, **Aiur** calls ElevenLabs speech-to-text with the credential below, and the transcript is delivered to the focused agent through the same operator-message path as the dashboard chat box. This is the only place the credential is configured — the Stream Deck sidecar never holds it. The section may be omitted entirely; the defaults below apply.

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `elevenlabs.api_key` | string or nil | nil | ElevenLabs speech-to-text credential. Accepts a literal value or a `$ELEVENLABS_API_KEY` environment reference. |
| `elevenlabs.language_code` | string | `eng` | ISO-639-3 transcription language. ElevenLabs uses `eng` for English. |

`ELEVENLABS_API_KEY` is the environment variable for the credential. An explicit `elevenlabs.api_key` value wins; when the key is absent, or is the `$ELEVENLABS_API_KEY` reference, the variable supplies it. An environment variable set to the empty string resolves to no key.

The key is a secret. Keep it in `.env` and leave the `$ELEVENLABS_API_KEY` reference in the config file rather than pasting the value there. Aiur never logs the key, and the daemon scrubs every `*_API_KEY` variable — `ELEVENLABS_API_KEY` included — from agent process environments, local and SSH-launched alike, so no coding agent inherits it.

Configuring the key also adds an ElevenLabs meter to the Dashboard Units page, beside the GitHub API meter. It reads the account credit quota from `GET /v1/user/subscription`; with no key configured the meter is absent entirely. See [API meters](/guide/executor-control-center#api-meters) for what the figure does and does not measure.

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

The receiver fails closed. A delivery is rejected with `401` when the signature header is absent, malformed, or does not match, and when `AIUR_GITHUB_WEBHOOK_SECRET` is unset or blank. The unset case also raises a needs-attention `system.github_webhook.secret_missing` alert, because a misconfigured deployment must never accept unsigned deliveries. The legacy SHA-1 `X-Hub-Signature` header is ignored and is never accepted as a fallback. Deliveries larger than 25 MB, GitHub's own delivery ceiling, are refused.

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

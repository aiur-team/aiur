# Configuration reference
Configuration lives in `.aiur/config` (YAML), and `prompt_file:` and `hooks_file:` point at sibling files. With no local config, Aiur uses `~/.aiur/config` without per-repository init. Global GitHub startup announces its current-origin target and ensures workflow/marker and complexity labels, without creating model labels.
Omit `tracker.github.repo` for portable defaults; a conflicting explicit repo fails safely. Shared credentials can live in `~/.aiur/.env` using the precedence below.

Older root-level config files are rejected. When moving one, also move the files it references, or rewrite their paths so they still resolve from the new config directory.
Supported secret and workspace-root fields resolve `~` and `$VAR` values; other path fields do not generally expand environment references.

## Environment variables

Environment variables are declared once in the env schema (`Aiur.Env.Schema`), which validates them at startup and generates the checked-in `.env.example` (run `mix aiur.env.example` from `src/` to regenerate; a CI check fails when the example drifts from the schema).

- **Layering.** Shell exports win, then `./.env`, then `~/.aiur/.env`: the launcher reads the repository file first and each file fills only unset names, so the home file only fills the gaps. A blank value such as the `GITHUB_TOKEN=` placeholder `aiur init` writes is not a setting and shadows nothing. GitHub credentials (`GITHUB_TOKEN` and the `GITHUB_APP_*` set) resolve as one group: when `./.env` sets any of them, every GitHub credential in `~/.aiur/.env` is ignored, so a machine-wide App never outranks the token a repository configured for itself. When the home value loses either way, the daemon logs a startup warning naming the variable (never its value).
- **Required vs optional.** The only configuration that aborts a boot is the GitHub credential (`GITHUB_TOKEN`, a `gh` keyring login via `gh auth login`, or the complete GitHub App set — `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and one of `GITHUB_APP_PRIVATE_KEY_PATH` / `GITHUB_APP_PRIVATE_KEY`) and the tracker configuration. Every integration — GitHub App auth, webhooks, Linear, voice, dashboard, Supervisor Decision API, provider keys — is optional; absence disables the feature and is reported once at startup, never a boot failure.
- **All-or-nothing credential groups.** A partially configured group (one dashboard credential without the other, or some but not all GitHub App credentials) fails at startup naming the missing members; a fully absent group is a supported setup.
- **Type validation.** Values that fail their declared type (for example `AIUR_OPENCODE_BRIDGE_PORT=banana`) abort the boot naming the variable and what was expected, instead of failing at first use hours later.
- **Secrets never leak.** Secrets render as an empty placeholder in `.env.example` and are excluded from error text and startup warnings. No real value from any `.env` file reaches the generated example, logs, or error output.
- **Dashboard credentials** (`AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD`) are values an operator chooses and types into a browser; see [GUI](/guide/gui) for choosing and setting them. Without them the dashboard refuses all requests (fails closed); the CLI and TUI are unaffected.

The generated `.env.example` groups variables under `## Required`, `## Optional - ...` (one section per integration), `## Runtime - launcher-managed`, and `## Development and debugging` headers, with a one-line purpose above each key and a terse right-hand "how to fetch" note aligned to a common column.

## Top-level
| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `max_vertical_panes` | integer | 3 | Caps visible agent chat panes. |
| `pre_warmed_sessions` | integer | 3 | Number of opencode sessions booted early; 0 disables pre-warm. |
| `max_log_history_mb` | integer | 1000 | Caps persistent log history in MB. |
| `prompt_file` | string | nil | Per-repository Liquid prompt template. |
| `debug` | boolean | false | Enables debug-level file logging without the CLI debug flag; background runs already retain normal-level logs. |
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
| `tracker.propagate_blocker_pushes` | boolean or nil | nil | Unset enables optimistic queue members; otherwise false. Cascade direct blocker pushes into idle dependents. Coalesces for 2 seconds, at most 2 propagations concurrently. Live agents pull themselves; conflicts dispatch rework. |
| `tracker.restack_after_blocker_merge` | boolean | true | Fast-forward restack idle GitHub dependents after a blocker squash-merges. Requires git 2.40+. Live agents restack themselves; false disables only the daemon path. |
| `tracker.base_branch` | string | required | Branch agents target with PRs. `aiur init` offers the repository default read from GitHub, but there is no runtime fallback: an unset value raises. |
| `tracker.active_states` | array | tracker-specific | States eligible for dispatch. GitHub values are lifecycle label slugs such as `todo` and `in-progress`, not display names. |
| `tracker.terminal_states` | array | tracker-specific | States that stop work. GitHub values are lifecycle label slugs such as `done`. |
| `tracker.terminal_fence_grace_seconds` | integer | 30 | How long a terminal tracker observation remains lifecycle-fenced while an authoritative queued item is still undelivered. |
| `tracker.github.max_inflight` | integer | 4 | Cap on concurrent tracker HTTP requests across all endpoints (1-100). |
| `tracker.github.max_inflight_per_endpoint` | integer | 2 | Cap on concurrent requests to any single tracker endpoint (1-100). Must not exceed `tracker.github.max_inflight`. |
| `tracker.github.requests_per_minute` | integer | 120 | Tracker request budget per minute (1-10000). Lower it when the tracker rate-limits Aiur. |
| `tracker.github.stagger_ms` | integer | 75 | Delay inserted between tracker requests, in milliseconds (0-5000), so a poll cycle does not burst. |
| `tracker.github.daemon_core_limit_per_hour` | integer | 3000 | Hourly billable Core (REST) response ceiling for the daemon actor. A `304` is reconciled as free. When the daemon hits the ceiling, only its requests hold until the rolling hour rolls back under it. `0` disables. |
| `tracker.github.daemon_graphql_limit_per_hour` | integer | 4500 | Hourly billable GraphQL response ceiling for the daemon actor. `0` disables. Raised from 2000 because the guard now books the high-level GraphQL-on-the-wire reads (`gh pr view/list/status/checks`, `gh issue view/list/status`, `gh search issues/prs`, `gh api graphql`) to the GraphQL window, and the App-token daemon alone measures ~3,400-4,300 such requests per hour. |
| `tracker.github.daemon_search_limit_per_hour` | integer | 600 | Hourly billable ceiling for GitHub's separate `search` pool (`gh search repos/code/commits/users` hit REST `/search/*`, metered at roughly 30 requests per minute rather than 5,000/hour). `0` disables. |
| `tracker.github.agent_core_limit_per_hour` | integer | 250 | Hourly billable Core (REST) response ceiling for each agent workspace. When one agent hits it, only that agent holds. `0` disables. |
| `tracker.github.agent_graphql_limit_per_hour` | integer | 600 | Hourly billable GraphQL response ceiling for each agent workspace. `0` disables. Raised from 375 so a single agent's normal loop (`pr view`/`issue view`/`pr checks`) has headroom once high-level GraphQL commands book to the GraphQL window. |
| `tracker.github.agent_search_limit_per_hour` | integer | 600 | Hourly billable ceiling against the `search` pool for each agent workspace. `0` disables. Kept separate from core and graphql because GitHub meters the search pool independently and it throttles first. |
| `tracker.github.credentials` | array | `[]` | Additional GitHub credentials the daemon spreads read traffic across, so one exhausted budget does not stop the fleet. Empty — the default — means one credential resolved exactly as before. See [Credential pooling](/apis/github#credential-pooling). |
| `tracker.github.credentials.id` | string | required | Lowercase identifier naming this credential in `aiur github-usage` and `aiur github-cost`. Must be unique. |
| `tracker.github.credentials.kind` | string | `machine_user` | One of `app_installation`, `machine_user` or `human`. Set it to `human` for a real person's token so Aiur keeps writes off that identity. |
| `tracker.github.credentials.identity` | string | nil | The GitHub login this credential authenticates as. Reporting only, so a usage row names an account rather than a hash. |
| `tracker.github.credentials.token_env` | string | required except for `app_installation` | Environment variable holding the token. An `app_installation` credential mints its own and needs none. A variable that is not exported drops the credential from the pool rather than failing boot. |
| `tracker.github.credentials.writes` | boolean | `false` | Whether this credential may carry writes (comments, labels, merges, PR creation). A `human` credential cannot be set to `true`: GitHub attributes the write to that person and it breaks the agent-authors / human-reviews separation the merge policy depends on. |
| `tracker.github.credentials.enabled` | boolean | `true` | Set to `false` to keep a credential in the file but out of the pool, for a token being rotated or an account temporarily rate-limited. |
| `tracker.github.repo` | string | the checkout's `origin` remote | GitHub owner/name used by Aiur. Omitted or left blank, it auto-detects from the `origin` remote of the directory the daemon was launched from — both for the repository Aiur polls and for the repository tracker identities are qualified by, which is what lets several daemons for different repositories share one `~/.aiur/config`. A value that is present but not `owner/name` is rejected rather than auto-detected, so a typo cannot silently redirect a fleet at whatever checkout it happens to run from. Set it explicitly whenever the daemon should track a repository other than its own checkout. |
| `tracker.github.label_prefix` | string | `agent` | Prefixes lifecycle labels. |
| `tracker.github.bot_account` | string | nil | Login the **agents** publish as — the account that pushes branches, opens pull requests, and comments for a ticket. This is an identity, not the credential: the credential is `GITHUB_TOKEN`. During fresh setup, `aiur init` asks whether agents use your own account or a separate bot account; it derives the former without asking for the login again and asks for the latter once. If the known posting credential names a different account, setup keeps that separate identity rather than recording an untrue shared account. In a non-interactive or `--force` run, valid resolved defaults are used and invalid ones are omitted rather than retried. Re-running `aiur init` preserves an existing value. When no `tracker.github.github_app.account` is set this login also stands in as the daemon's own identity for self-loop suppression. |
| `tracker.github.identity_mode` | string | `separate_account` | Whether the agents post as a login no human uses (`separate_account`) or share the operator's own login (`single_account`). Stated, never inferred: nothing compares `bot_account` against the token's viewer login to guess, because that guess is wrong in both directions and silently changes which comments wake an agent. Under `separate_account` the author login proves authorship and nothing else is needed. Under `single_account` it proves nothing, so Aiur appends an invisible HTML-comment marker to comments it writes and suppresses only comments carrying it — anything unmarked, including every comment posted before this existed, reads as human and wakes the agent. Any other value is rejected at config load. |
| `tracker.github.github_app.account` | string | nil | Optional. The GitHub App bot login (`<app-slug>[bot]`) the **daemon** writes as when App credentials are configured (see [GitHub](/apis/github#github-app-authentication)). Set it only when the daemon's identity differs from the agents': an App installation token can never write as `tracker.github.bot_account`, so one key naming both would make every agent-authorship check demand a login no agent holds. Leave it unset for a single-identity install — self-loop suppression, PR command handling and the CODEOWNERS self-include then fall back to `tracker.github.bot_account` exactly as before. Only the login lives here; the App credentials stay in `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID` and `GITHUB_APP_PRIVATE_KEY_PATH`. |
| `tracker.github.trusted_accounts` | array | `[]` | Usernames allowed to direct agents. |
| `tracker.github.allowed_users` | array | `[]` | GitHub logins allowed to use trusted operator paths. |
| `tracker.github.allowed_contributors` | map | nil | Whole intake allow-list: `users: [42]`, `orgs: [{id: 77, login: acme}]`. Positive numeric int64 ids; logins address the membership API only. Present empty map/null admits nobody; present key skips `.github/ALLOWED-CONTRIBUTORS`. Invalid entries fail startup validation. Reload/restart applies changes and alerts with added/removed entries. |
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
| `polling.intervals` | map of class → integer | `%{}` | Per-class poll cadences in seconds. Each key names a poll class — `dispatch`, `ci`, `review`, `planning`, `firehose` — and overrides `interval_seconds` for that class only. A class with no entry falls back to `interval_seconds`, so an unset map keeps today's single-interval behaviour exactly. `0` means the class is on-demand — no timer, refreshed only when a consumer explicitly asks — which is the recommended value for `planning`. (`firehose` is not recommended at any value: its loop rides the dispatch tick and is not gated, so an entry would be a dead knob.) `dispatch` must be a positive integer: the dispatch tick always runs, so `dispatch: 0` is rejected. `review` only diverges on a repo proven webhook-backed — on a polling repo its safety net stays at the dispatch rate. An unknown class key or a negative value is rejected. |
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
  | `ci` | check state on a pull request with work in flight | Expensive GraphQL and urgent, but only while a PR is actually in flight (the loop is demand-scoped). `intervals.ci` is deliberately not recommended: the loop rides the dispatch tick, so a value below `dispatch` is inert (the loop can never fire more often than the tick) and one above it *slows* CI detection — a stale CI read has agent-visible consequences. Leave it unset to inherit `interval_seconds`. |
  | `review` | comments and review threads | Expensive GraphQL, moderately urgent, and webhook-covered for comment *arrival* — the poll is a safety net, so minutes is defensible. The divergence is enforced, not asserted: on a repo not proven webhook-backed the class resolves to the dispatch cadence, so the safety net never silently slows on a polling repo. |
  | `planning` | Build Order catalog, pack status, ad-hoc listings | The most expensive reads and the least urgent. Recommended value `0` (on-demand): the catalog's only consumers are web pages and it is demand-gated, so it needs no timer. |
  | `firehose` | repo events | Already self-regulating via GitHub's `X-Poll-Interval`; the class exists so status can show its configured cadence, not to change its loop. The firehose loop is **not gated** on a class cadence — it rides the dispatch tick — so no value is recommended: leave it unset to inherit `interval_seconds`. An entry would be a dead knob. |

- The dashboard, the Units catalog and Build Order ticket history all judge
  staleness against the effective interval of the class they mean: the
  orchestrator snapshot readers derive from `dispatch`, Build Order catalog and
  ticket history from `planning`.
- Build Order's remaining `graph_catalog_refresh_ms` — the failure-backoff base
  for the catalog scope, the window after which the catalog snapshot is shown
  as ageing, and the floor the labelled-read cadence rides on — is derived from
  the effective `planning` interval, so an idle fleet widens the Build Order
  backoff exactly as it widens the tracker poll.
- The catalog itself is event-sourced (#2313): the page renders the store
  projection, there is no recurring sweep, and the only GitHub reads are the
  rare reconciliation (daemon boot and degraded webhook delivery). It is not
  demand-gated by who is looking — the reconciliation is the daemon-owned
  writer that re-converges the store — and it needs no timer. A selected root's
  staleness window and failure backoff are therefore re-based on delivery
  latency (`webhooks.silence_threshold_seconds`), the gap after which
  degradation triggers the reconciliation, rather than on a poll cadence.
- So a change to an interval needs no matching threshold edit.
- `aiur status` prints the effective value and the live interval per class, for
  example:
  ```
  POLL idle backoff active: interval=1200s base=120s factor=5.0x
  POLL class intervals: ci=120s dispatch=120s firehose=120s planning=0s review=300s
  ```
  `0s` means the class is on-demand: no timer, refreshed only when a consumer
  asks. `ci` sits at the dispatch cadence because the loop rides the tick and is
  deliberately not given its own interval; `review` shows its configured value
  only while the repo is proven webhook-backed.
- The idle widening only applies once the daemon has observed an idle cycle:
  a freshly restarted fleet starts at the base interval, and a live fleet with
  dispatchable tickets keeps the base interval so work is not left waiting
  behind a backed-off sweep (#2138).

## monitoring

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `monitoring.daemon_heartbeat_stale_ms` | integer | 3,600,000 | Threshold in milliseconds for recording a retrospective daemon heartbeat gap on Executor startup. A durable `system.daemon.gap` informational event is emitted only when a stale heartbeat is corroborated by the lifecycle journal; its cause is `clean_shutdown` when a stop was recorded and `unknown` for an unclosed start. Missing heartbeat files are ignored. This is not live monitoring and cannot alert while Aiur is stopped. Default is 1 hour (3,600,000 ms). |

## webhooks

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `webhooks.repos` | list of `owner/name` | `[]` | Repos expected to deliver webhooks. A hint only. A listed repo keeps polling at full rate until it actually delivers. |
| `webhooks.silence_threshold_seconds` | integer | 900 | How long a proven repo may go without a delivery before it degrades back to full polling and raises a needs-attention alert. |
| `webhooks.sweep_interval_seconds` | integer | 60 | How often proven repos are checked for silence. |
| `webhooks.poll_widen_factor` | float | 2.0 | Multiplier applied to `polling.interval_seconds` for repos proven webhook-backed. Values below 1.0 are rejected. |

See [GitHub polling and webhooks](/apis/github) for the setup story and runtime states.

## workspace

The `wip_*` keys bound the save of uncommitted work described in [Saved uncommitted work](/reference/cli#saved-uncommitted-work).

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `workspace.root` | string path | tmp `aiur_workspaces` | Root for agent workspaces. |
| `workspace.bootstrap_image` | string | nil | Docker image for warm build-cache seeding. |
| `workspace.bootstrap_image_pull` | boolean | false | Pulls the bootstrap image before seeding. |
| `workspace.wip_max_bytes` | integer | 52428800 | Cap in bytes of one save of uncommitted work (50 MiB). Untracked files past it are skipped; the tracked patch is always kept. |
| `workspace.wip_max_file_bytes` | integer | 10485760 | An untracked file larger than this (10 MiB) is skipped in a save. |
| `workspace.wip_max_dir_files` | integer | 10000 | An untracked directory with more files than this, or a nested repository, is skipped whole. |
| `workspace.wip_command_timeout_ms` | integer | 60000 | Time limit of each `git` and `tar` command of a save. A timeout keeps the workspace, except for a closed ticket. |
| `workspace.wip_retention_bytes` | integer | 2147483648 | Cap in bytes of all of `wip-preserved/` (2 GiB). Closed tickets' saves are pruned first. |
| `workspace.wip_retention_days` | integer | 14 | Saves older than this are pruned. The newest save of an open ticket is never pruned. |

## worker

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `worker.ssh_hosts` | array | `[]` | SSH hosts available for remote execution. Each server must allow `BASH_ENV`, `ENV`, `HOME`, and `ZDOTDIR` through OpenSSH `AcceptEnv`; Aiur neutralizes them before the account shell starts and fails closed if the server rejects them. |
| `worker.max_concurrent_agents_per_host` | integer or nil | nil | Per-host concurrent-agent cap. |

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

This optional section configures voice features; `aiur init` records declines as `enabled: false` and skips them on resume.

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `elevenlabs.enabled` | boolean | true | Enables ElevenLabs voice features. Set false to keep an explicit declined setup choice and suppress configured or environment-provided credentials. Existing configs without this key remain enabled. |
| `elevenlabs.api_key` | string or nil | nil | ElevenLabs credential. Accepts a literal value or a `$ELEVENLABS_API_KEY` environment reference. Speech input needs Speech to Text permission; spoken replies also need Text to Speech permission. |
| `elevenlabs.language_code` | string | `eng` | ISO-639-3 transcription language. ElevenLabs uses `eng` for English. |
| `elevenlabs.voice_id` | string or nil | nil | Stock or owned ElevenLabs voice used for Dashboard interactive conversation replies. Find the identifier in **My Voices**; Aiur does not clone or manage voices. |

`ELEVENLABS_API_KEY` is the environment variable for the credential. When `elevenlabs.enabled` is true, an explicit `elevenlabs.api_key` value wins; when the key is absent, or is the `$ELEVENLABS_API_KEY` reference, the variable supplies it. `enabled: false` suppresses both sources. An environment variable set to the empty string resolves to no key.

The key is a secret. Keep it in `.env` and leave the `$ELEVENLABS_API_KEY` reference in the config file rather than pasting the value there. Aiur never logs the key, and the daemon scrubs every `*_API_KEY` variable, `ELEVENLABS_API_KEY` included, from agent process environments, local and SSH-launched alike, so no coding agent inherits it.

Configuring the key also adds an ElevenLabs meter to the Dashboard Units page, beside the GitHub API meter. It reads the account credit quota and next-invoice amount due from `GET /v1/user/subscription`; with no key configured the meter is absent entirely. See [API meters](/concepts/units#api-meters) for what each figure does and does not measure.

## observability

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `observability.dashboard_enabled` | boolean | true | Reserved compatibility setting; use the launch-time `--no-dashboard` flag to suppress the listener in foreground or background mode. |
| `observability.dashboard_writable` | boolean | true | Enables dashboard write paths. Set to `false` to disable them. A dashboard bound beyond loopback refuses to start without both dashboard basic-auth environment variables; a loopback listener binds without them and fails closed (see below). |
| `observability.build_order_funnel_health_check` | boolean | false | Opts into one bounded startup check of the local Build Order endpoint and configured Tailscale Funnel HTTPS 443 target. Leave disabled when Funnel serves another purpose. |
| `observability.refresh_ms` | integer | 1000 | Dashboard data refresh interval. |
| `observability.render_interval_ms` | integer | 16 | Minimum render interval. |
| `observability.telemetry_enabled` | boolean | true | Records run telemetry for analytics. |
| `observability.telemetry_retention_max_bytes` | integer | 67108864 | Maximum retained telemetry bytes. |
| `observability.telemetry_retention_max_age_days` | integer | 30 | Maximum retained telemetry age. |
| `observability.telemetry_retention_prune_interval_bytes` | integer or nil | nil | Bytes between retention-prune checks. |

`dashboard_writable` is an authorization gate, not an authentication mechanism. Every usable dashboard requires `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`.

A loopback listener — writable or read-only — may bind without them, but its authentication plug fails closed and refuses every dashboard request until both credentials are set. A dashboard bound beyond loopback refuses to start without both credentials.

When `observability.build_order_funnel_health_check` is enabled, Aiur checks the configured dashboard bind address at `/build-orders/1` and reads `tailscale funnel status --json` once after dashboard startup. Both command timeouts are five seconds, and timed-out Tailscale processes are terminated.

The one-time check is suppressed when `server.tailscale_funnel: true`. The reconciler reports Funnel health after its initial and periodic attempts, so the startup check cannot alert before reconciliation runs.

HTTP 200, redirects 301/302/304/307/308, and 401 (authentication required) count as reachable. Other statuses, including 201, 204, and 303, do not.

A stale proxy target raises `system.build_order_funnel.target_mismatch`; an unreachable endpoint raises `system.build_order_funnel.target_unreachable`; and an endpoint timeout raises `system.build_order_funnel.target_timeout`.

An unavailable or unparseable Tailscale status raises `system.build_order_funnel.health_check_error`. Tailscale is not detected or queried unless this setting is explicitly enabled.

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
| `server.host` | string | `127.0.0.1` | HTTP bind address. Set it explicitly to serve the dashboard beyond the machine; there is no automatic Tailscale detection. |
| `server.tailscale_funnel` | boolean | false | Reconcile an already-enabled Tailscale Funnel HTTPS route on port 443 to the dashboard's current bound host and port at startup and every 30 seconds. Requires the Tailscale CLI and an existing Funnel route; failures raise a Build Order Funnel alert and retry. |

When `server.host` is absent, the dashboard binds `127.0.0.1` (or the `AIUR_DEFAULT_DASHBOARD_HOST` override). A configured value is never replaced by that default. An explicit `--host` remains the highest-precedence override.

Set `server.tailscale_funnel: true` only when this node already has a Funnel route the operator intends to keep. At startup and every 30 seconds, Aiur reads the dashboard's bound host and port and updates the route with `tailscale funnel --bg` when needed.

Before changing a different target, Aiur probes that target's `/build-orders/1`. Any HTTP response makes the reconciler leave the route unchanged and raise `system.build_order_funnel.target_mismatch`.

Only a connection-refused probe counts as stale and permits an update. Timeouts, TLS failures, and other probe errors leave the route unchanged and raise `system.build_order_funnel.health_check_error` with cause `unknown`. Wildcard binds (`0.0.0.0` and `::`) map to loopback for the Funnel target.

Enable this on only one Aiur daemon per node. A second daemon with this key enabled can repoint the route while the owning dashboard restarts and its old target refuses connections.

When `server.tailscale_funnel` is enabled, the reconciler suppresses the separate `observability.build_order_funnel_health_check` startup check and reports its own failures after each reconciliation attempt.

A non-root account needs Tailscale operator access before Aiur can manage the route. Grant it once with `sudo tailscale set --operator=$USER`; then run Aiur as that account.

Aiur does not enable Funnel or create a route. The dashboard's existing authentication remains in place, and the route supports HTTP and WebSocket traffic.

The target probe is a bounded liveness check, not proof of daemon identity or route ownership. A live stale service requires operator intervention. Aiur does not restart, stop, or otherwise manage the Tailscale daemon.

A fixed `server.port` that is already bound — for example a second `aiur` instance on the same host — does not crash the daemon. The second instance logs an explicit startup message naming the port and the conflict, disables only its own dashboard, and keeps running agents.

The durable repository Executor state also records every daemon start and stop in `<repo>.control-lifecycle.json`, with the invoking process's OS pid, parent pid, and hostname. All runs for that repository share the journal, so a second instance or a crash is identifiable after the fact even when each run has a different log directory.

## opencode

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `opencode.command` | string | `opencode` | Command launching opencode. |
| `opencode.bridge_port` | integer | 4097 | Aiur↔opencode bridge port. |
| `opencode.bridge_host` | string | `127.0.0.1` | Aiur↔opencode bridge host. |
| `opencode.serve_args` | array | `[]` | Extra `opencode serve` arguments. |
| `opencode.model_prefix` | string | `aiur` | Prefix for registered synthetic models. |
| `opencode.prewarm_disabled` | boolean | false | Disables opencode session pre-warming. |

## build_queue

Build queue configuration for GitHub workflows (Linear is unsupported); the daemon reconciles stored queue membership after tracker signals or on the configured interval, with a two-second debounce.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `build_queue.start_trigger` | string | `pr_merged` | Prerequisite stage needed for queue promotion: `issue_closed`, `pr_merged`, `pr_approved`, `pr_ci_green`, or `pr_opened`. A queue can override it with `--start-on`; missing or stale evidence never releases dependents. Optimistic stages combine lifecycle labels with retained per-PR progress. `pr_approved` adds a conditional review read only for watched blockers. |
| `build_queue.enabled` | boolean | true | Enable build queue reconciliation. The server maintains dispatch hints, promotes ready items, and withdraws todo from unclaimed items whose prerequisites change. Disabling the queue removes its server and hints table on the next run. |
| `build_queue.reconcile_interval_seconds` | integer | 60 | Reconciliation interval in seconds; 10..3600. |
| `build_queue.max_writes_per_minute` | integer | 20 | Queue write budget per minute; 1..60. |
| `build_queue.observation_max_age_seconds` | integer or null | derived (2× polling.interval_seconds) | Maximum observation age in seconds; null derives twice the base poll interval (240 seconds by default); explicit values must be 10..3600. |
| `build_queue.merged_open_grace_seconds` | integer | 600 | Grace period in seconds for an `issue_closed` queue prerequisite whose PR merged but issue remains open; 60..86400. |

## Further sections

- [`agent`, host-pressure admission, `agent.claude`, `agent.codex`, model discovery](/reference/configuration-agent)
- [`build_order` and resolution notes](/reference/configuration-build-order)

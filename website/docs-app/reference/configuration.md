# Configuration reference

Choose a topic below. Existing section links lead to the same reference content.

- [Daemon configuration](./configuration-daemon)
- [Tracker and polling configuration](./configuration-tracker)
- [Integration configuration](./configuration-integrations)
- [Agent configuration](./configuration-agent)
- [Build Order configuration](./configuration-build-order)
- [Voice configuration](./configuration-voice)
- [Configuration notes](./configuration-notes)

## Environment variables
Environment variables are declared once in `Aiur.Env.Schema`, which validates them at startup and generates `.env.example` (`mix aiur.env.example` from `src/`; CI rejects drift).
- **Layering.** Shell exports win, then `./.env`, then `~/.aiur/.env`: the launcher reads the repository file first and each file fills only unset names, so the home file only fills the gaps. A blank value such as the `GITHUB_TOKEN=` placeholder `aiur init` writes is not a setting and shadows nothing. GitHub credentials (`GITHUB_TOKEN` and the `GITHUB_APP_*` set) resolve as one group: when `./.env` sets any of them, every GitHub credential in `~/.aiur/.env` is ignored, so a machine-wide App never outranks the token a repository configured for itself. When the home value loses either way, the daemon logs a startup warning naming the variable (never its value).
- **Hosted environment-only mode.** Set `AIUR_SECRETS_FROM_ENV=1` on the daemon to skip both dotenv files. Startup and `aiur status` report missing tracker credentials, remote-dashboard credentials and allowlist, webhook secrets, non-persistent-state signing keys, and keys required by configured provider routes together by variable name; secret values are never included. Set `AIUR_STATE_PERSISTENT=1` only when the state directory survives daemon restarts; otherwise `AIUR_SECRET_KEY_BASE` is required. Hosted/container GitHub auth defaults to the App; set `AIUR_GITHUB_ALLOW_PAT=1` to explicitly allow `GITHUB_TOKEN` as the fallback.
- **Required vs optional.** Tracker configuration is required. Local GitHub startup accepts `GITHUB_TOKEN`, a `gh` keyring login via `gh auth login`, or the complete GitHub App set — `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and one of `GITHUB_APP_PRIVATE_KEY_PATH` / `GITHUB_APP_PRIVATE_KEY`. Hosted/container GitHub startup requires the App unless `AIUR_GITHUB_ALLOW_PAT=1` explicitly opts into `GITHUB_TOKEN`; the keyring is not a hosted fallback. Other integrations — webhooks, Linear, voice, dashboard, Supervisor Decision API, provider keys — are optional; absence disables the feature and is reported once at startup, never a boot failure.
- **All-or-nothing credential groups.** A partially configured group (one dashboard credential without the other, or some but not all GitHub App credentials) fails at startup naming the missing members; a fully absent group is a supported setup.
- **Type validation.** Values that fail their declared type (for example `AIUR_OPENCODE_BRIDGE_PORT=banana`) abort the boot naming the variable and what was expected, instead of failing at first use hours later.
- **Secrets never leak.** Secrets render as an empty placeholder in `.env.example` and are excluded from error text and startup warnings. No real value from any `.env` file reaches the generated example, logs, or error output. Dashboard credentials use `AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD` for machine Basic Auth and optional browser fallback. Google browser sign-in uses `AIUR_GOOGLE_CLIENT_ID` / `AIUR_GOOGLE_CLIENT_SECRET` ([GUI](/guide/gui)). `AIUR_SECRET_KEY_BASE` (at least 64 bytes, e.g. `openssl rand -base64 48`) overrides the cookie key; otherwise Aiur persists a mode-0600 key per instance under `~/.aiur/instances/`.

[Read this section](./configuration-daemon#environment-variables).

## Top-level

[Read this section](./configuration-daemon#top-level).

## executor

[Read this section](./configuration-daemon#executor).

## tracker

[Read this section](./configuration-tracker#tracker).

## polling

[Read this section](./configuration-tracker#polling).

## monitoring

[Read this section](./configuration-daemon#monitoring).

## webhooks

[Read this section](./configuration-tracker#webhooks).

## workspace

[Read this section](./configuration-daemon#workspace).

## worker

[Read this section](./configuration-daemon#worker).

## hooks

[Read this section](./configuration-daemon#hooks).

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

The alert fires only once a hold has persisted past the routine bound: a probe that fails or exceeds its own timeout, a build that genuinely holds the fleet, or a stalled hold the watchdog releases. Its `.resolved` fires when the gate clears.
[Read this section](./configuration-daemon#prewarm).

## pr_watch

[Read this section](./configuration-daemon#pr-watch).

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

It also runs the **head-verdict router** on the same interval. At the open, non-draft PR's head, the configured reviewer's `CHANGES_REQUESTED` moves `agent:human-review`, `agent:ci-wait` or `agent:error` to `agent:rework`.

An `APPROVED` that follows their same-head `CHANGES_REQUESTED` moves `agent:rework` to `agent:ci-wait`. An error ticket moved to rework raises `system.pr_health.error_rework`. Each review routes once.

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
| `events.export.enabled` | boolean | false | Enables signed outbound webhook delivery. |
| `events.export.max_pending_events` | integer | 10000 | Maximum admitted events waiting for acknowledgement. |
| `events.export.request_timeout_ms` | integer | 15000 | Per-attempt webhook request timeout. |
| `events.export.retry_ms` | integer | 5000 | Delay before retrying a failed delivery. |
| `events.export.subject_id` | string | nil | Delivers only events for this exact ticket or job identifier. |
| `events.export.webhook_url` | string | nil | HTTPS endpoint receiving outbound event POSTs. |

## upgrade

The `aiur run` upgrade-version notice is optional and opt-out: it caches with a TTL (the registry is contacted at most once a day), fails open and silent when unreachable, never runs under `aiurdev`, and is channel-aware — a `nightly` or `next` user is never offered a lower `latest`.

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-12 -->
| --- | --- | --- | --- |
| `upgrade.check_enabled` | boolean | true | Enables the `aiur run` version notice and its registry check. Set false to suppress the check entirely (zero outbound calls). |

`AIUR_UPGRADE_CHECK_DISABLED` (and the legacy `AIUR_NO_UPDATE_NOTIFIER`) are the environment-variable equivalents; the check also stays silent in CI runs.
[Read this section](./configuration-daemon#pr-health).

## events

[Read this section](./configuration-daemon#events).

## upgrade

[Read this section](./configuration-daemon#upgrade).

## alerts

[Read this section](./configuration-daemon#alerts).

## usage

[Read this section](./configuration-daemon#usage).

## elevenlabs

[Read this section](./configuration-integrations#elevenlabs).

## compaction

[Read this section](./configuration-daemon#compaction).

## observability

[Read this section](./configuration-daemon#observability).

## decisions

[Read this section](./configuration-daemon#decisions).

## server

[Read this section](./configuration-daemon#server).

## dashboard_auth

[Read this section](./configuration-daemon#dashboard-auth).

## opencode

[Read this section](./configuration-integrations#opencode).

## experiments

[Read this section](./configuration-integrations#experiments).

## build_queue

[Read this section](./configuration-daemon#build-queue).

## Further sections

[Read this section](./configuration-daemon#further-sections).

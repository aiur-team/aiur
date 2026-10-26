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

[Read this section](./configuration-daemon#environment-variables).

## Top-level

[Read this section](./configuration-daemon#top-level).

Environment variables are declared once in the env schema (`Aiur.Env.Schema`), which validates them at startup and generates the checked-in `.env.example` (run `mix aiur.env.example` from `src/` to regenerate; a CI check fails when the example drifts from the schema).
- **Layering.** Shell exports win, then `./.env`, then `~/.aiur/.env`: the launcher reads the repository file first and each file fills only unset names, so the home file only fills the gaps. A blank value such as the `GITHUB_TOKEN=` placeholder `aiur init` writes is not a setting and shadows nothing. GitHub credentials (`GITHUB_TOKEN` and the `GITHUB_APP_*` set) resolve as one group: when `./.env` sets any of them, every GitHub credential in `~/.aiur/.env` is ignored, so a machine-wide App never outranks the token a repository configured for itself. When the home value loses either way, the daemon logs a startup warning naming the variable (never its value).
- **Hosted environment-only mode.** Set `AIUR_SECRETS_FROM_ENV=1` on the daemon to skip both dotenv files. Startup and `aiur status` report missing tracker credentials, remote-dashboard credentials and allowlist, webhook secrets, non-persistent-state signing keys, and keys required by configured provider routes together by variable name; secret values are never included. Set `AIUR_STATE_PERSISTENT=1` only when the state directory survives daemon restarts; otherwise `AIUR_SECRET_KEY_BASE` is required. Hosted/container GitHub auth defaults to the App; set `AIUR_GITHUB_ALLOW_PAT=1` to explicitly allow `GITHUB_TOKEN` as the fallback.
- **Required vs optional.** Tracker configuration is required. Local GitHub startup accepts `GITHUB_TOKEN`, a `gh` keyring login via `gh auth login`, or the complete GitHub App set — `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and one of `GITHUB_APP_PRIVATE_KEY_PATH` / `GITHUB_APP_PRIVATE_KEY`. Hosted/container GitHub startup requires the App unless `AIUR_GITHUB_ALLOW_PAT=1` explicitly opts into `GITHUB_TOKEN`; the keyring is not a hosted fallback. Other integrations — webhooks, Linear, voice, dashboard, Supervisor Decision API, provider keys — are optional; absence disables the feature and is reported once at startup, never a boot failure.
- **All-or-nothing credential groups.** A partially configured group (one dashboard credential without the other, or some but not all GitHub App credentials) fails at startup naming the missing members; a fully absent group is a supported setup.
- **Type validation.** Values that fail their declared type (for example `AIUR_OPENCODE_BRIDGE_PORT=banana`) abort the boot naming the variable and what was expected, instead of failing at first use hours later.
- **Secrets never leak.** Secrets render as an empty placeholder in `.env.example` and are excluded from error text and startup warnings. No real value from any `.env` file reaches the generated example, logs, or error output. Dashboard credentials use `AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD` for machine Basic Auth and optional browser fallback. Google browser sign-in uses `AIUR_GOOGLE_CLIENT_ID` / `AIUR_GOOGLE_CLIENT_SECRET` ([GUI](/guide/gui)). `AIUR_SECRET_KEY_BASE` (at least 64 bytes, e.g. `openssl rand -base64 48`) overrides the cookie key; otherwise Aiur persists a mode-0600 key per instance under `~/.aiur/instances/`.
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

[Read this section](./configuration-daemon#prewarm).

## pr_watch

[Read this section](./configuration-daemon#pr-watch).

## pr_health

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

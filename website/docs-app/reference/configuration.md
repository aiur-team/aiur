# Configuration reference

Choose a topic below. Existing section links lead to the same reference content.

- [Changing config on a running daemon](#changing-config-on-a-running-daemon)
- [Daemon configuration](./configuration-daemon)
- [Tracker and polling configuration](./configuration-tracker)
- [Integration configuration](./configuration-integrations)
- [Agent configuration](./configuration-agent)
- [Build Order configuration](./configuration-build-order)
- [Voice configuration](./configuration-voice)
- [Configuration notes](./configuration-notes)

## Environment variables

[Read this section](./configuration-daemon#environment-variables).
Environment variables are declared once in `Aiur.Env.Schema`, which validates them at startup and generates `.env.example` (`mix aiur.env.example` from `src/`; CI rejects drift).

- **Layering.** Shell exports win, then `./.env`, then `~/.aiur/.env`: the launcher reads the repository file first and each file fills only unset names, so the home file only fills the gaps. A blank value such as the `GITHUB_TOKEN=` placeholder `aiur init` writes is not a setting and shadows nothing. GitHub credentials (`GITHUB_TOKEN` and the `GITHUB_APP_*` set) resolve as one group: when `./.env` sets any of them, every GitHub credential in `~/.aiur/.env` is ignored, so a machine-wide App never outranks the token a repository configured for itself. When the home value loses either way, the daemon logs a startup warning naming the variable (never its value).
- **Hosted environment-only mode.** Set `AIUR_SECRETS_FROM_ENV=1` on the daemon to skip both dotenv files. Startup and `aiur status` report missing tracker credentials, remote-dashboard credentials and allowlist, webhook secrets, non-persistent-state signing keys, and keys required by configured provider routes together by variable name; secret values are never included. Set `AIUR_STATE_PERSISTENT=1` only when the state directory survives daemon restarts; otherwise `AIUR_SECRET_KEY_BASE` is required.
- **Required vs optional.** The only configuration that aborts a boot is the GitHub credential (`GITHUB_TOKEN`, a `gh` keyring login via `gh auth login`, or the complete GitHub App set — `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and one of `GITHUB_APP_PRIVATE_KEY_PATH` / `GITHUB_APP_PRIVATE_KEY`) and the tracker configuration. Every integration — GitHub App auth, webhooks, Linear, voice, dashboard, Supervisor Decision API, provider keys — is optional; absence disables the feature and is reported once at startup, never a boot failure.
- **All-or-nothing credential groups.** A partially configured group (one dashboard credential without the other, or some but not all GitHub App credentials) fails at startup naming the missing members; a fully absent group is a supported setup.
- **Type validation.** Values that fail their declared type (for example `AIUR_OPENCODE_BRIDGE_PORT=banana`) abort the boot naming the variable and what was expected, instead of failing at first use hours later.
- **Secrets never leak.** Secrets render as an empty placeholder in `.env.example` and are excluded from error text and startup warnings. No real value from any `.env` file reaches the generated example, logs, or error output.
- **Dashboard credentials/key.** Set `AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD` for machine Basic Auth and optional browser fallback. Google browser sign-in uses `AIUR_GOOGLE_CLIENT_ID` / `AIUR_GOOGLE_CLIENT_SECRET` ([GUI](/guide/gui)). `AIUR_SECRET_KEY_BASE` (at least 64 bytes, e.g. `openssl rand -base64 48`) overrides the cookie key; otherwise Aiur persists a mode-0600 key per instance under `~/.aiur/instances/`.

## Changing config on a running daemon

The daemon checks `.aiur/config` once per second and reloads valid changes without restarting; running agent turns continue. Settings read by live consumers, including `agent.max_concurrent_agents`, `agent.target_cpu_pressure`, and `agent.max_cpu_pressure`, apply live. Settings documented as **read once at daemon start** need a restart; examples include `instance.id`, `instance.mode`, `instance.role`, `events.export.enabled`, and `observability.telemetry_enabled`. Changing the dashboard bind address or port (`server.host` or `server.port`) also requires a restart to rebind the listener. Environment changes require a restart.

If a file change fails parsing or validation, Aiur keeps the last good config and raises `system.config.reload_rejected`. Check `aiur status`: `CONFIG RELOAD REJECTED` remains until a corrected config loads.

Deploy a build that recognizes a new config key before adding that key to `.aiur/config`. An older running build cannot apply a key it does not know, so keep the config compatible with the running build until the upgrade is deployed.

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

## netlify

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-24 -->
| --- | --- | --- | --- |
| `netlify.account_id` | string | nil | Netlify team/account ID to read. |
| `netlify.credit_alert_threshold` | integer | 0 | Emit a low-credit alert at or below this estimated balance; 0 disables the threshold. |
| `netlify.enabled` | boolean | false | Enable the read-only Netlify usage poller and dashboard card. |
| `netlify.poll_seconds` | integer | 900 | Netlify usage polling interval in seconds. |

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

## Machine settings (`~/.aiur/machine`)

This optional YAML file shares mobile settings and the `accounts` registry across
the machine, independently of repository workflows.

| Key | Type | Default | Validation |
| --- | --- | --- | --- |
| `machine:mobile.enabled` | boolean | `false` | Enables mobile access when consumed. |
| `machine:gateway.host` | string | `127.0.0.1` | IP address or resolvable host. |
| `machine:gateway.port` | integer | `4710` | 1–65535; zero cannot provide a stable paired endpoint. |
| `machine:gateway.endpoints` | string array | `[]` | Absolute HTTP(S) URLs without path, query, fragment or credentials. |
| `machine:pairing.secret_ttl_seconds` | integer | `600` | 60–3600 seconds. |
| `machine:pairing.max_devices` | integer | `20` | 1–200 devices. |
| `machine:pairing.pin_rotation_grace_seconds` | integer | `604800` | At least 3600 seconds; applies to T-B transport. |
| `machine:transport.tls.cert_file` | path | `null` | Expands `~`; existence is checked by the transport consumer. |
| `machine:transport.tls.key_file` | path | `null` | Expands `~`; existence is checked by the transport consumer. |
| `machine:transport.tls.bind_host` | string | `null` | IP literal. |
| `machine:transport.tls.advertise_host` | string | `null` | DNS name without scheme or port. |
| `machine:transport.allow_cleartext_overlay` | boolean | `false` | Allows eligible overlay transport when consumed. |
| `machine:transport.cleartext_overlay_cidrs` | CIDR array | `["100.64.0.0/10", "fd7a:115c:a1e0::/48"]` | IPv4 or IPv6 prefixes; catch-all `/0` ranges are rejected. |

Account registration, logout and settings writes preserve the other top-level
sections. Malformed machine files cause account writes to return an error without
replacing the file.

Missing or empty files use defaults. Machine settings never create or read
`~/.aiur/config`. The loader is available now; mobile commands and transport
consumers are introduced separately.

Unknown keys within these sections produce errors naming every offending dotted
key. Unknown top-level sections are ignored and preserved by partial writes.
Writes lose YAML comments, replace the file atomically with mode `0600`, and create
a missing `~/.aiur` directory with mode `0700`. Existing broader file permissions
do not prevent reading.

`Aiur.Machine.Settings.load/0` reads and validates the file each time; `get/0`
caches by modification time, size and inode. Both return `{:ok, settings}` or
`{:error, reason}`.

A failed reload retains the last good settings with its
`last_error` field set; deleting the file restores defaults. Callers requiring a
security decision must treat an unreadable file as mobile disabled.

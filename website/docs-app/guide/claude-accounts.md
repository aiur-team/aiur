# Accounts by backend

Account profiles are machine-local; they do not belong in repository
configuration. Claude and Codex support isolated profile directories. Kimi,
DeepSeek, and OpenRouter support named API keys. Muse uses its native single
login and does not support isolated accounts.

## Add an account

Create a Claude or Codex profile and sign in interactively:

```sh
aiur login claude work
aiur login codex work
```

To adopt a profile that already exists elsewhere:

```sh
aiur login claude work --dir "$HOME/Claude-work"
```

Claude profiles link shared settings, instructions, plugins, skills, and
project memory. Claude identity files, transcripts, sessions, history, remote
settings, and policy limits stay private.

Codex profiles link only `config.toml` and `skills`; `auth.json` and state
databases are never shared. The existing `~/.claude` and `~/.codex` directories
remain the `default` accounts and are not copied or moved.

For API-key backends, add a named key to `~/.aiur/.env`, for example
`DEEPSEEK_API_KEY__WORK=...`, then register the account with `aiur login`:

```sh
aiur login deepseek work
```

Use the provider's base variable name followed by `__` and the uppercase
account name. Keys remain in the env file; the machine account registry stores
only the variable name. Per-key identity and usage are unavailable for these
backends and are shown as unavailable.

List account identity and usage without exposing credentials:

```sh
aiur accounts
aiur accounts codex --json
```

Usage percentages and freshness come from the daemon's last poll. If Aiur is
not running, the command still shows account identity and reports usage as
unavailable; it does not make a separate usage request.

The daemon polls Claude usage every `polling.usage_interval_seconds` while
agents run or a dashboard is in focus, in any `account_selection` mode. A
shorter `agent.headroom_reading_max_age_seconds` clamps that cadence down to
the provider's 120-second polling floor. A max age below 120 seconds can become
stale between probes. Older readings show as `stale`.

When polls fail, Claude rows show `last_error`. After an earlier good reading
the row is `stale` with that reading's age. Three failures in a row log one
warning.

A running daemon serves the same rows over HTTP, behind dashboard basic auth:

| Endpoint | Returns |
| --- | --- |
| `GET /api/v1/usage/accounts` | `{contract: "aiur.usage.accounts", contract_version: 1, observed_at, accounts: [...]}`. Each row is the matching `aiur accounts --json` row, limited to an allowlist: identity labels, `weekly_percent`, `five_hour_percent`, `remaining_percent`, `freshness`, `observed_at`, `age_ms` and, on Claude rows, `last_error`. |
| `GET /api/v1/usage/accounts?harness=codex` | The same envelope, limited to one harness. |

Every row has a `freshness` value:

| `freshness` | Numbers |
| --- | --- |
| `fresh`, `cached` | Current Claude meter reading. |
| `stale` | Claude reading older than `agent.headroom_reading_max_age_seconds`; numbers are kept and `age_ms` shows how old they are. A failing poll after an earlier good reading is also `stale`, with numbers `null`. |
| `ledger` | Read from the usage ledger (a backend with one account). |
| `stale_ledger` | Ledger reading past the max age; numbers are `null`, `age_ms` is kept. |
| `usage_not_observed` | Claude account the daemon has not polled yet. |
| `usage_not_polled` | Backend without a per-account meter or a usable ledger reading. |
| `usage_unavailable` | API-key account; no per-key meter. |
| other | Reason the last poll failed, for example `no_oauth_token`. |

A missing reading is `null`, never `0`. Each row carries only the listed
fields, and `identity` carries only `email`, `organization`, `seatTier` and
`account_id`. Responses are `Cache-Control: no-store` and never include
credentials, API keys or profile paths.

## Enable accounts for dispatch

Add account names to the repository's `.aiur/config`. Names in the list are
priority order:

```yaml
agent:
  accounts:
    claude: [default, work]
    codex: [default, work]
    deepseek: [default, work]
  account_selection: priority
```

`balance` selects the account with the lowest weekly utilization, using
five-hour utilization to break ties. `priority` uses the first configured
account. Usage-aware selection currently applies to Claude and Codex.

`headroom` looks across backends as well as accounts: each new ticket goes to
the backend and account with the most usage left, within the routes its
complexity level allows. See
[Headroom dispatch](/concepts/headroom-dispatch).

## Continue a session after a usage limit

When a resumable Claude REPL session reaches its account's usage limit, Aiur
selects another configured Claude account using the same `account_selection` rule.

Only these resumable `claude-repl` sessions can hand off. Headless `claude`
sessions use the aiur-claude app-server, whose in-memory thread map cannot be
recreated from a moved transcript: `thread/start` cannot seed a prior session.
Those sessions keep waiting for the current account to reset.

If one is available, Aiur moves the inactive session transcript and related
session artifacts to that profile. It then resumes from the original working
directory under the new account, and status shows the account now running the
session.

If no other configured account has room, Aiur keeps the existing
wait-for-reset behavior.

The dashboard shows a named weekly remaining bar for each Claude account, with
freshness and observation age. A full bar is 100% left; an empty bar is
unusable until reset. Missing readings remain unknown.

The CLI and Stream Deck summary selects the highest weekly utilization, falling
back to the highest reported window when weekly usage is absent. The displayed
bars and percentages show the remaining share, so the summary names the least
remaining account when all weekly readings are available.

If an account could not be read, the summary names the selected account and the
observed account count instead.

API-key accounts have unavailable usage, so use `priority` when those backends
have multiple keys. The chosen account stays fixed for that ticket's session.

Claude usage includes weekly and five-hour account readings. Codex identities
come from auth metadata, never token contents; its usage probe reads the
selected `CODEX_HOME`. API-key accounts currently have no per-key identity or
usage reading, so Aiur reports usage unavailable for those rows.

Remove an account from the registry while keeping its files:

```sh
aiur logout claude work
```

Add `--purge` only when you also want to delete that named profile directory.
Aiur never removes `default`.

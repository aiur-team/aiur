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

The combined Claude usage bar gives every account an equal-width segment and
reports the average weekly utilization. Each account's utilization and
freshness remain visible in its label and tooltip.
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

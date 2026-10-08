# Claude accounts

Aiur can dispatch Claude workers across multiple Claude Code logins on one
machine. Account profiles are machine-local; they do not belong in repository
configuration.

## Add an account

Create a profile and sign in interactively:

```sh
aiur login claude work
```

To adopt a profile that already exists elsewhere:

```sh
aiur login claude work --dir "$HOME/Claude-work"
```

Aiur links shared settings, instructions, plugins, skills, and project memory
from the default Claude profile. It does not link Claude identity files,
transcripts, sessions, history, remote settings, or policy limits. The existing
`~/.claude` remains the `default` account and is not copied or moved.

List account identity and usage without exposing credentials:

```sh
aiur accounts
aiur accounts --json
```

## Enable accounts for dispatch

Add account names to the repository's `.aiur/config`. Names in the list are
priority order:

```yaml
agent:
  accounts:
    claude: [default, work]
  account_selection: balance
```

`balance` selects the account with the lowest weekly utilization, using
five-hour utilization to break ties. `priority` uses the first configured
account that is below both limits. Unavailable usage is never treated as zero
and ranks after known readings. The chosen account stays fixed for that ticket's
session.

## Continue a session after a usage limit

When a resumable Claude REPL session reaches its account's usage limit, Aiur
selects another configured Claude account using the same `account_selection`
rule. If one is available, Aiur moves the inactive session transcript and
related session artifacts to that profile, then resumes from the original
working directory under the new account. Status shows the account now running
the session. If no other configured account has room, Aiur keeps the existing
wait-for-reset behavior.

The combined Claude usage bar gives every account an equal-width segment and
reports the average weekly utilization. Each account's utilization and
freshness remain visible in its label and tooltip.

Remove an account from the registry while keeping its files:

```sh
aiur logout claude work
```

Add `--purge` only when you also want to delete that named profile directory.
Aiur never removes `default`.

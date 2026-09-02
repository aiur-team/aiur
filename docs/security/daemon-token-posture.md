# Daemon token posture

The daemon must use a GitHub App installation token, rather than a personal
access token. Installation tokens identify the machine integration, are scoped
to an installation's repositories, and expire after roughly one hour.

The App must be granted only:

- Contents: read and write
- Issues: read and write
- Pull requests: read and write

It must not receive Administration, Actions, Secrets, or Workflows permission.
Token issuance, refresh, and client migration are tracked by #1375, alongside
the rate-limit work in #678. This ticket deliberately records the posture and
does not broaden the merge-boundary change into an authentication migration.

Ruleset administration remains an operator-only action. No Administration
credential is stored in Actions or given to the daemon.

`aiur init` may inspect repository readiness with a separately supplied,
one-shot `AIUR_CI_READINESS_TOKEN`. That operator credential needs only
Contents, Actions, and Administration read access for the inspection endpoints;
it must not be stored in `.env` or inherited by the daemon.

---

## Setting up the GitHub App (implemented by #1375)

### 1. Create the App and install it

1. Create a GitHub App at **Settings → Developer settings → GitHub Apps →
   New GitHub App** (organization owner is fine; the App is installed on the
   target repository).
2. Grant **only** these permissions (Repository permissions):
   - **Contents: Read and write**
   - **Issues: Read and write**
   - **Pull requests: Read and write**
   - (GitHub always adds `Metadata: Read-only` implicitly — this is expected.)
3. Do **not** grant Administration, Actions, Secrets, or Workflows, and do not
   request any Organization permissions.
4. Generate and download a **private key** (a `.pem` file). Keep it in a secure
   store — it is the App's signing credential and can mint installation tokens
   for every repository the App is installed on.
5. Install the App on the target repository (or organization), and note the
   **installation id** from the installation URL
   (`https://github.com/settings/installations/<installation_id>`).

### 2. Configure the daemon

The daemon reads App credentials from the same `.env` the launcher sources
(GitHub App values are never written to `.aiur/config`):

```sh
GITHUB_APP_ID=123456                # the App's numeric id
GITHUB_APP_INSTALLATION_ID=12345678 # the installation id from step 1.5
GITHUB_APP_PRIVATE_KEY_PATH=/path/to/app.private-key.pem
```

`GITHUB_APP_PRIVATE_KEY_PATH` is preferred over `GITHUB_APP_PRIVATE_KEY`
(inline PEM) so the key never appears in the process environment or shell
history. When App credentials are configured, the daemon authenticates with a
fresh installation token and ignores `GITHUB_TOKEN`; `GITHUB_TOKEN` remains the
fallback when no App credentials are present.

### 3. How the token lifecycle works

- At boot the daemon signs a JWT (`RS256`, `iss` = app id, 10-minute lifetime)
  with the App private key, exchanges it at
  `POST /app/installations/{installation_id}/access_tokens`, verifies the token
  is rate-limit-usable, and caches it.
- A supervised refresher re-acquires a fresh token **before** the ~1-hour
  expiry (5-minute safety margin) for the life of the daemon.
- A refresh failure emits a **needs-attention** alert
  (`system.github_app_token.refresh_failed`) and retries with capped backoff; the last
  known-good token keeps being used until it expires.
- The exchange response's `permissions` map is verified against the
  least-privilege set above. A grant beyond it (for example
  `administration: write`) emits a **needs-attention** alert
  (`system.github_app_token.permission_violation`).

### 4. Daemon identity under App auth (required)

Switching from a PAT to an installation token **changes who the daemon is on
GitHub**, and this must be reconciled in config or the daemon will start
reacting to its own writes.

- A PAT authenticates as the operator account (for example `its-applekid`).
- An installation token authenticates as the App's **bot user**,
  `<app-slug>[bot]` (for example `aiur-daemon[bot]`). Every API-created
  comment, label change, review and pull request is attributed to that login.

`tracker.github.bot_account` is the single place Aiur records "this is me", and
it is load-bearing for:

- **Self-loop suppression** — `Aiur.Events.Publisher` drops events whose actor
  equals `Aiur.GitHub.Config.daemon_account/0` — the App bot login when one is
  configured, otherwise `bot_account` (except authoritative `.pr.merged` events,
  which publish regardless of actor). Left pointing at the PAT account, the App
  bot's own comments are not recognized as self and are republished back into
  the orchestrator.
- **PR command self-loop drop** — `Aiur.Events.PrCommandScanner` ignores `/aiur`
  comments authored by `bot_account`; a mismatch lets an agent re-trigger itself.
- **CODEOWNERS self-include** — the trust allowlist always unions in
  `bot_account`, so a wrong login drops that fail-closed safety net.
- **Review-thread reply verification** compares against `bot_account` when it is
  set, falling back to the token's own viewer login when it is nil. A *wrong*
  `bot_account` therefore breaks it; an unset one does not.

**So: when you enable App auth, set `tracker.github.bot_account` to the App bot
login, `<app-slug>[bot]`.** The daemon checks this at startup and emits a
needs-attention `system.github_app_token.identity_mismatch` alert when App
credentials are configured and `bot_account` is unset or is not a `[bot]`
login. Confirm the exact login by looking at the author of any comment the
daemon posts after the switch.

## Identity modes: `tracker.github.identity_mode`

Everything above assumes the agents post as a login no human uses. That is the
default and is spelled `separate_account`. Where it holds, the author login of a
comment is proof of who wrote it, and self-loop suppression needs nothing else.

A solo operator running Aiur on their own repository usually has no second
account, so the agents and the human share one login. Say so:

```yaml
tracker:
  github:
    identity_mode: single_account
```

The mode is **stated, never inferred**. Nothing compares `bot_account` against
the token's viewer login to guess it, because that comparison is true for an
operator who runs the daemon under their dedicated bot and false for one whose
single account is a machine user — and guessing wrong in either direction
silently changes which comments wake an agent.

In `single_account` the author login proves nothing, so provenance moves into
the comment body. Aiur appends `Aiur.GitHub.AgentMarker`'s HTML-comment marker
to every comment it writes — daemon-side in `Aiur.GitHub.Comments`, agent-side
in the `gh` wrapper, which is the only point an agent's own body passes
through. `Aiur.Events.Publisher` then suppresses a comment from the shared login
only when that marker is present.

The failure direction is deliberate. Authorship is decided by the **presence**
of the marker, never its absence, so anything unmarked — a comment posted before
this existed, one written with `--body-file`, one whose body could not be read —
is treated as **human**. The cost of being wrong is one redundant agent wake.
The opposite default would silently swallow an operator's instruction.

Two consequences worth knowing:

- Comments that predate the marker read as human. An agent re-woken by its own
  old comment is expected and self-clears once it replies with a marked one.
- `separate_account` installs are untouched: no body is rewritten, the wrapper
  leaves argv alone, and the gate behaves exactly as it did before.

One asymmetry is expected and is not a misconfiguration: **git commits keep
their configured author** (the installation token is used only as the HTTPS
credential for push, not as the commit author), while **GitHub API objects are
authored by the App bot**. Add the App bot login to `trusted_accounts` if any
gate needs to trust it beyond the `bot_account` self-include.

### 5. Verifying least privilege

- In the GitHub App settings page, confirm the Repository permissions are
  exactly Contents, Issues, and Pull requests (plus the implicit Metadata).
- After a refresh, the daemon's alert/log line
  `github_app_token refreshed expires_at=...` indicates a healthy rotation; a
  `system.github_app_token.permission_violation` alert means the App holds more than
  the posture allows and must be corrected at the App settings page.

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

### 4. Verifying least privilege

- In the GitHub App settings page, confirm the Repository permissions are
  exactly Contents, Issues, and Pull requests (plus the implicit Metadata).
- After a refresh, the daemon's alert/log line
  `github_app_token refreshed expires_at=...` indicates a healthy rotation; a
  `system.github_app_token.permission_violation` alert means the App holds more than
  the posture allows and must be corrected at the App settings page.

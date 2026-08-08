---
title: "feat: Migrate daemon authentication to scoped GitHub App installation token"
type: feat
status: in-progress
date: 2026-08-03
origin: https://github.com/aiur-team/aiur/issues/1375
---

# feat: Migrate daemon authentication to scoped GitHub App installation token

## Summary

Replace the daemon's `GITHUB_TOKEN` personal-access-token with a short-lived
GitHub App installation token. The daemon acquires an installation token by
signing a JWT with the App's private key and exchanging it at the App
installations endpoint, caches it, refreshes it before its ~1 hour expiry, and
alerts (needs-attention) when a refresh fails. The configured App permission
set (Contents: write, Issues: read/write, Pull requests: write — no
Administration/Actions/Secrets/Workflows) is documented and verified against
the token GitHub actually grants. Existing GitHub API clients keep working
unchanged because the installation token is served through the same
`GitHub.Config.token/0` seam, and the rate-limit/exhaustion recovery work from
#678 is preserved.

## Problem Frame

Today the daemon authenticates every GitHub REST/GraphQL call and every
networked `git` operation with a single `GITHUB_TOKEN` PAT (resolved at boot by
`Aiur.GitHub.Config.resolve_token/1`, cached in `:persistent_term`, and served
by `Config.token/0`). A PAT is long-lived, carries every scope its account was
granted (often `repo` — effectively all repo permissions), is shared with the
operator's `gh` keyring fallback, and cannot be scoped per-installation. The
daemon posture doc (`docs/security/daemon-token-posture.md`) already records
the required end state: a GitHub App installation token with only Contents,
Issues, and Pull requests permissions, never Administration/Actions/Secrets/
Workflows.

A GitHub App installation token expires after roughly one hour, so the daemon
needs an acquisition + refresh lifecycle that (a) does not block the pollers,
(b) refreshes before expiry, and (c) surfaces refresh failures as
Executor-visible needs-attention alerts instead of silently wedging the fleet.

## Assumptions

*This plan was authored without synchronous user confirmation. The items below
are agent inferences that fill implementation details not fixed by the issue
and should remain visible during review.*

- The existing `GITHUB_TOKEN` PAT path stays as the fallback when no GitHub App
  credentials are configured, so the migration is opt-in per deployment and
  existing tests/configs keep working.
- Credentials are supplied as environment variables in the same `.env` file the
  daemon already loads (`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and
  `GITHUB_APP_PRIVATE_KEY` or `GITHUB_APP_PRIVATE_KEY_PATH`). A key file path is
  preferred over inline PEM so the key is not echoed into process listings.
- Installation selection is an explicit `GITHUB_APP_INSTALLATION_ID`; the App
  must be installed on the target org/repository. Auto-discovery of the
  installation by org is a documented future enhancement, not part of this
  change.
- The installation-token exchange response's `permissions` map is authoritative
  evidence of the granted permission set and is used for the least-privilege
  verification.
- `jose` (the de-facto Elixir/Erlang JOSE library) is added as the JWT signing
  dependency; hand-rolling RS256 signing is rejected for a security ticket.

## Requirements

- R1. GitHub App credentials (`app id`, `installation id`, private key) are
  securely loaded from environment/`.env` and validated; missing or malformed
  credentials produce a clear diagnostic, never a crash or a logged secret.
  Traces to issue #1375, `docs/security/daemon-token-posture.md`.
- R2. The daemon acquires an installation token by exchanging a JWT (signed
  RS256 with the App private key, `iss` = app id, `iat`/`exp` within GitHub's
  ten-minute JWT window) for `POST /app/installations/{id}/access_tokens`.
  Traces to GitHub App authentication documentation.
- R3. The acquired token is cached with its `expires_at` and refreshed before
  the ~1 hour expiry; a refresh failure emits a needs-attention alert and
  retries with capped backoff. Traces to issue #1375 "Refresh installation
  tokens before their approximately one-hour expiry" and "report refresh
  failures as needs-attention alerts".
- R4. The permission set granted to the installation token is verified against
  the allowed least-privilege set (Contents: write, Issues: read/write,
  Pull requests: write, plus the implicit `metadata: read`); any extra
  permission is surfaced as a needs-attention alert and logged. Traces to issue
  #1375 "The configured permission set is documented and verified as least
  privilege".
- R5. Existing GitHub API clients use the installation token without change:
  `Config.token/0` serves the installation token whenever App credentials are
  configured, so `Transport.require_token/1`, the git auth header in
  `RepoBase.git_auth_env/1`, and every `Aiur.GitHub.*` client inherit it.
  Traces to issue #1375 "Existing GitHub API clients use the installation
  token".
- R6. Rate-limit/exhaustion recovery from #678 is preserved: the token source
  is transparent to `Aiur.GitHub.Errors`/`Aiur.GitHub.Connectivity`, and the
  acquired installation token is validated as rate-limit-usable (the existing
  "remaining == 0 ⇒ unusable" posture) before it is trusted. Traces to #678.
- R7. Documentation: GitHub App creation, private-key download, installation,
  env-var setup, installation selection, and the exact least-privilege
  permission set with a verification procedure are recorded. `.env.example` and
  `docs/security/daemon-token-posture.md` are updated. Traces to issue #1375
  acceptance bullets 1 and 3.

## Implementation Units

### Unit 1 — JWT dependency

- Add `{:jose, "~> 1.11"}` to `src/mix.exs` deps; run `mix deps.get` to refresh
  `src/mix.lock`. Verified by `mix compile --warnings-as-errors`.

### Unit 2 — `Aiur.GitHub.AppCredentials`

- `src/lib/aiur/github/app_credentials.ex`. Reads `GITHUB_APP_ID`,
  `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY` (inline PEM) or
  `GITHUB_APP_PRIVATE_KEY_PATH` (file path; preferred).
- `configured?/0` — all three (id, installation id, key) present.
- `app_id/0`, `installation_id/0` — normalized non-empty strings.
- `private_key_pem/0` — reads file or inline value; never logged.
- `parse_private_key/0` — `{:ok, %JOSE.JWK{}} | {:error, :missing_private_key | :invalid_private_key}`.
- Failure modes are pure; the module never raises.

### Unit 3 — `Aiur.GitHub.AppToken` (pure acquisition)

- `src/lib/aiur/github/app_token.ex`.
- `app_jwt(credentials, now \\ DateTime.utc_now())` — builds and RS256-signs
  the GitHub App JWT with `jose`; `iss` = app id, `iat` = now, `exp` = now + 10
  minutes.
- `exchange_token(request_fun, jwt, installation_id)` — `POST
  https://api.github.com/app/installations/{id}/access_tokens` with
  `Authorization: Bearer <jwt>`; parses `token` + `expires_at` (ISO8601);
  returns `{:ok, %{token: ..., expires_at: ..., permissions: ...}}` or
  `{:error, {:github, classification, detail}}`.
- `allowed_permissions/0` — `%{"contents" => "write", "issues" => "write",
  "pull_requests" => "write", "metadata" => "read"}`.
- `verify_permissions(granted)` — `:ok` when granted is a subset of
  `allowed_permissions/0`, else `{:error, %{extra: ...}}`. Presence of
  administration/actions/secrets/workflows → violation.
- `refresh_delay_ms(expires_at, now, opts)` — ms until the refresh timer fires:
  `expires_at - now - margin` (default margin 5 min), floored at a minimum
  positive interval; handles already-expired tokens.
- No token material is ever logged; error returns are structural.

### Unit 4 — `Aiur.GitHub.AppTokenRefresher` (GenServer lifecycle)

- `src/lib/aiur/github/app_token_refresher.ex`.
- Owns `:persistent_term` cache `{token, expires_at, permissions}` keyed
  `{__MODULE__, :installation_token}`.
- `current_token/0` — pure persistent-term read (no GenServer dependency), so
  `Config.token/0` can serve it in tests and before the tree starts.
- `cache_token(token, expires_at, permissions)` — pure persistent-term write,
  public for `Config.resolve_token/1` and tests.
- `start_link/1`; `init/1` reads the cache; acquires only when absent; schedules
  refresh via `Process.send_after(self(), :refresh, delay)`.
- `handle_info(:refresh, state)` — re-acquire; on success cache + reschedule; on
  failure emit `Aiur.Alerts.emit_custom("github_app_token.refresh_failed", ...,
  needs_attention: true, reason: ...)` and schedule a capped-backoff retry.
  Permission violations trigger a separate needs-attention alert and do not
  discard the token.
- Refresh delay is clamped to a minimum interval (never a no-op `send_after` of
  0).

### Unit 5 — `Aiur.GitHub.Config` integration

- `token/0` — when `AppCredentials.configured?/0`, return
  `AppTokenRefresher.current_token/0`; else the existing PAT
  env/persistent-term path. Backward compatible (app path inactive by default).
- `resolve_token/1` — when App credentials are configured, acquire the token
  synchronously (blocking exchange at boot, mirroring today's boot-time
  rate-limit probe), validate it is rate-limit-usable (remaining > 0), cache it,
  and return it; on any failure log a warning (never crash boot) and return nil
  (the refresher keeps retrying + alerting). The existing PAT path is untouched.
- `validate!/0` — when App credentials are configured and no token is available,
  error message names the App credential env vars instead of `GITHUB_TOKEN`.

### Unit 6 — Auth preflight messaging

- `src/lib/aiur/github/auth_preflight.ex` — diagnostic `token_source` becomes
  `"GITHUB_APP"` when App credentials are configured, `"GITHUB_TOKEN"`
  otherwise; the recovery message reflects the active source without logging
  any credential material.

### Unit 7 — Supervision tree

- `src/lib/aiur.ex` — add `Aiur.GitHub.AppTokenRefresher` as a child (early,
  before the Orchestrator/firehose children) so refresh continues for the life
  of the daemon.

### Unit 8 — Documentation

- `docs/security/daemon-token-posture.md` — expand with concrete setup:
  create the App, generate/download the private key, install it on the target
  org, record the installation id, set env vars (prefer
  `GITHUB_APP_PRIVATE_KEY_PATH`), and the exact permission checkboxes with a
  verify procedure (inspect the exchange response's `permissions` or the App
  settings page).
- `.env.example` — add `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`,
  `GITHUB_APP_PRIVATE_KEY`, `GITHUB_APP_PRIVATE_KEY_PATH` with comments; note
  that `GITHUB_TOKEN` remains the fallback.
- `.aiur/examples/config.example` — note in the `bot_account` comment that the
  daemon credential is the App installation token when configured.

### Unit 9 — Tests

- `src/test/aiur/github/app_credentials_test.exs` — configured?/parse/error
  paths; asserts no credential string appears in returned values.
- `src/test/aiur/github/app_token_test.exs` — JWT shape (header alg=RS256,
  typ=JWT, iss=app id, iat/exp window), exchange success/failure parsing
  (injected `request_fun`), `verify_permissions` least-privilege (allowed set
  ok; administration/actions/secrets/workflows extra → violation),
  `refresh_delay_ms` bounds.
- `src/test/aiur/github/app_token_refresher_test.exs` — init acquires when
  cache empty, refresh before expiry reschedules, refresh failure emits a
  needs-attention alert via an injected emitter and schedules a retry,
  permission violation emits an alert, token material never appears in alert
  messages/logs.
- `src/test/aiur/github/config_test.exs` additions — `token/0` serves the
  installation token when App credentials are configured; `resolve_token/1`
  acquires + caches; PAT fallback still returns the env token when App creds
  are absent.

## Test Scenarios

- TS1. `app_jwt/2` produces a JWT whose decoded header is
  `%{"alg" => "RS256", "typ" => "JWT"}` and payload `iss` equals the app id
  with `exp - iat` within 10 minutes; a trivially wrong implementation
  (wrong key/issuer) fails the assertion.
- TS2. `exchange_token/3` with an injected `request_fun` returning 200 +
  `%{"token" => ..., "expires_at" => ...}` yields the parsed token/expiry; a
  401/403/429 maps to the `{:github, classification, detail}` taxonomy.
- TS3. `verify_permissions/1` accepts exactly Contents/Issues/Pull requests
  write + metadata read and rejects any administration/actions/secrets/
  workflows entry.
- TS4. Refresher: a token expiring in 30 minutes schedules a refresh; a
  simulated refresh failure emits exactly one needs-attention alert (asserted
  via an injected emit function) and schedules a retry, and no assertion can
  see a raw token value (the test asserts against redacted/structural
  messages).
- TS5. `Config.token/0` returns the cached installation token when App
  credentials are configured and returns the env PAT otherwise (existing PAT
  tests keep passing unchanged).
- TS6. `resolve_token/1` app path: injected `acquire_fun` success caches the
  token; a rate-limit-unusable token is not trusted; failure returns nil
  without raising.

## Risks

- **JWT signing correctness.** Mitigated by using `jose` and by asserting the
  decoded header/payload/signature shape in TS1 rather than only round-tripping
  through the same code under test.
- **Credential leakage.** The private key and installation token are never
  logged, never included in alert messages, and never returned from error
  structs. Tests assert the absence of credential material (TS4).
- **Regressing the PAT path / rate-limit recovery (#678).** The app path is
  strictly additive and gated on `AppCredentials.configured?/0`; existing
  config tests run unchanged; `Errors`/`Connectivity` are untouched.
- **Boot-order dependency.** `Config.resolve_token/1` acquires the initial
  token before the supervision tree starts (same pattern as today's boot-time
  rate-limit probe), so pollers never start without a cached token.
- **Dependency addition.** `jose` is pure Erlang/Elixir (no NIF), pinned with a
  `~>` constraint, and validated by the scoped pre-PR gate + CI.

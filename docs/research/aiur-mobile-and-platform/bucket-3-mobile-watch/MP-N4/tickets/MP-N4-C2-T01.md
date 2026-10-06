---
ticket_id: MP-N4-C2-T01
feature_id: MP-N4
chunk_id: MP-N4-C2
bucket: 3-mobile-watch
title: Relay service skeleton — handle registry, send endpoint, idempotency, storage
status: ready
blocked_by: [DESIGN-N4 (no-UI release)]
prior_units: []
prior_boundaries: [new — relay service is a separate deployable (MP-R1 component-map row push-relay)]
prior_features: [MP-R1, MP-R4]
prior_findings: [MP-Q2 resolution (platform-evidence.md)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C2-T01 — Relay service skeleton

## Identity and outcome

Bucket 3, MP-N4, chunk C2. Create the reference relay service as a standalone Mix project
`packages/aiur-push-relay/` (PROPOSED) that implements contract v2 §7–§8 **without**
provider adapters (C2-T02/T03 plug in): `POST /v1/handles`, `DELETE /v1/handles/:handle`,
`POST /v1/send` (bearer `send_secret`), `GET /healthz`. A `Provider` behaviour with a fake
implementation lets the whole HTTP surface be tested now.

User value: the opaque forwarder that lets a never-reachable machine send pushes.

Non-goals: APNs/FCM (T02/T03), rate limits (T04), container image and deployment (T05),
Workers (T06). The service never links aiur daemon code.

## Dependencies and blockers

- No aiur-internal dependency; DESIGN-N4 releases C2 (no UI).
- OQ-N4-1 (who operates the default relay, which accounts) does **not** block this code;
  it blocks deployment (T05) and production credentials.
- May run concurrently with all of C1 and C3.

## Verified starting point

- Repo layout at `45a290e3`: `packages/` holds `aiur-style`, `streamdeck`; no Elixir
  package there yet. The daemon project is `src/mix.exs` (Bandit `~> 1.12`,
  `exqlite ~> 0.27`, `jason`, `jose 1.11.12`, `req ~> 0.7`). The relay reuses the same
  vetted libraries and the same toolchain pin (`mise.toml`: erlang 28, elixir 1.19.5).
- Contract v2 §7 (handles), §8 (envelope incl. `idempotency_key`, `fallback`), §1 (what
  the relay sees).

## Chosen design

- **Stack:** Elixir, Plug + Bandit, SQLite via `exqlite` (one file, WAL). Rationale: same
  toolchain and review skills as the daemon; HTTP/2 client for APNs via Finch/Mint in
  T02. Cloudflare Workers is deferred (T06, blocked) because outbound HTTP/2 to APNs from
  Workers is unverified.
- **Storage interface** `AiurPushRelay.Store` (behaviour) with the SQLite implementation:
  table `handles(handle TEXT PK, platform, push_token, app_topic, environment,
  send_secret_sha256 BLOB, created_at, last_used_at)`; table
  `sends(handle, idempotency_key, status, created_at, PRIMARY KEY(handle, idempotency_key))`
  pruned after 24 h; table `send_log(handle, at, size, status)` pruned after 7 days.
- **Handles:** `h_` + 26 base32 chars (128 random bits); `send_secret` 32 random bytes,
  base64url; only `sha256(send_secret)` stored; comparison with
  `Plug.Crypto.secure_compare/2`.
- **Endpoints:**
  - `POST /v1/handles` body `{platform: "apns"|"fcm", push_token, app_topic,
    environment: "production"|"sandbox"}` → `201 {handle, send_secret}`. Validation:
    `app_topic` must be in the configured allowlist (the publisher's bundle ids / Firebase
    app ids, env `AIUR_RELAY_APP_TOPICS`), so the relay cannot be used for other apps.
  - `DELETE /v1/handles/:handle` with `Authorization: Bearer <send_secret>` → `204`;
    unknown → `404`.
  - `POST /v1/send` → `202` after the provider accepted the job into the in-process queue
    (contract: the relay does not wait for APNs); a repeated `(handle, idempotency_key)`
    within 24 h returns the first status, sends nothing.
  - Errors: `401` bad secret, `404 handle_unknown`, `410 handle_gone` (handle marked gone
    by a provider, T02/T03), `413` sealed too large (> 3,400 chars), `422` schema.
- **Provider behaviour:** `deliver(handle_row, envelope) :: :ok | {:gone, reason} |
  {:retry, after_ms} | {:error, reason}`; a `Fake` provider for tests.
- **Logging:** structured, `handle` + status + size only; `sealed`, `push_token`,
  `send_secret` are never logged (Logger metadata filter + test).

## Implementation steps

1. `packages/aiur-push-relay/mix.exs`, `mise.toml` mirroring the repo pin, `README.md`.
2. `lib/aiur_push_relay/{router.ex, store.ex, store/sqlite.ex, provider.ex,
   provider/fake.ex, handles.ex, send.ex}` (PROPOSED).
3. Supervision: Bandit, Store, a `Task.Supervisor` for provider deliveries.
4. Tests below.

## Non-happy paths

- DB locked/corrupt → `503` on writes, `/healthz` reports `store: error`; no partial
  handle rows (transaction).
- Duplicate `POST /v1/handles` for the same push token: allowed (one per machine by
  design, contract §7); no dedupe across handles.
- Clock skew irrelevant (relay stores its own times).
- Request body > 8 KB → `413` before JSON decode.

## Compatibility and rollout

New package; `v: 1` in envelope; unknown fields ignored. No effect on the daemon until
C3 points at a deployed URL.

## Verification

`packages/aiur-push-relay/test/` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `handles_test "create returns handle and secret, stores only the hash"` | DB row has 32-byte hash, no secret | store the plaintext secret |
| `handles_test "unknown app_topic is rejected"` | `422` | drop the allowlist check |
| `send_test "wrong secret is 401 and nothing is delivered"` | Fake provider got 0 calls | skip auth |
| `send_test "same idempotency_key twice sends once"` | 1 provider call, both `202` | remove the `sends` lookup |
| `send_test "gone handle answers 410"` | after Fake returns `{:gone, _}`, next send → 410 | ignore `{:gone,_}` |
| `log_test "sealed and push_token never reach the logger"` | `capture_log` lacks both strings | log the envelope |

Commands: `env -C packages/aiur-push-relay mise exec -- mix test`,
`env -C packages/aiur-push-relay mise exec -- mix format --check-formatted`.

## Completion and handoff

- [ ] Package builds and tests from a clean checkout; path-filtered CI job added in T05.
- Docs: package README only (operator docs ship with T05).
- Dependents: C2-T02, C2-T03, C2-T04, C2-T05, C3-T03 (contract client), C4-T05/C5-T05.

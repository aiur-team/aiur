# Aiur Push Relay

Standalone Elixir/Plug + Bandit reference relay. It does not depend on the Aiur daemon.
SQLite runs in WAL mode; back up and persist the database file. This package supplies
handle registration, bearer authentication, idempotency and asynchronous provider admission.
APNs/FCM adapters and deployment are configured independently. Abuse limits are separate work.

## Run and test

Use the repository's pinned Erlang 28.5 / Elixir 1.19.5 toolchain:

```sh
mise exec -- mix deps.get
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test --max-cases 4
mise exec -- mix format --check-formatted
```

Run these commands from `packages/aiur-push-relay`. To start with `mix run --no-halt`, set:

| Environment | Meaning |
| --- | --- |
| `AIUR_RELAY_APP_TOPICS` | Required comma-separated publisher bundle / Firebase app IDs |
| `AIUR_RELAY_FALLBACK_<APP_TOPIC_SLUG>` | Required JSON `{"title":"Aiur","body":"Open Aiur"}` per topic |
| `AIUR_RELAY_DATABASE` | SQLite file, default `relay.sqlite3` |
| `AIUR_RELAY_PORT` | HTTP port, default `4001` |
| `AIUR_RELAY_FCM_SERVICE_ACCOUNT_FILE` | Optional Firebase service-account JSON file; its group and other permission bits must be unset. Without it, FCM sends return `503 provider_unavailable`. |
| `AIUR_RELAY_SEND_PER_HOUR` | Per-handle token refill, default `60` sends/hour |
| `AIUR_RELAY_SEND_BURST` | Per-handle burst capacity, default `10` |
| `AIUR_RELAY_HANDLES_PER_IP_HOUR` | Handle creation burst and refill per source IP, default `20`/hour |
| `AIUR_RELAY_LOG_RETENTION_DAYS` | Send-log retention, default `7`; values above `7` prevent startup |

Rate-limit exhaustion returns `429 {"error":"rate_limited","retry_after_s":N}` and a
matching `Retry-After` header. Replaying an accepted idempotency key does not consume a
send token. SQLite persists token buckets across restarts; store failures fail closed with
`503`. The relay rejects request bodies above 8 KiB and sealed envelopes above 3,400
bytes. Idempotency rows expire after 24 hours; metadata-only send logs expire after the
configured retention period (at most seven days).

Topic slugs uppercase the topic and replace each non-ASCII-alphanumeric character with `_`.
Fallback title and body together must be at most 200 UTF-8 bytes. Missing or invalid pins
refuse startup. Configure a module implementing `AiurPushRelay.Provider` through the
`:aiur_push_relay, :provider` application setting. The default disabled provider records
an error; it never pretends to deliver a push. `Provider.Fake` is for tests only.

## HTTP contract

- `GET /healthz`: `200 {"store":"ok"}`, or `503 {"store":"error"}`.
- `POST /v1/handles`: JSON `{platform, push_token, app_topic, environment}`;
  platforms `apns` / `fcm`, environments `production` / `sandbox`. Returns
  `201 {handle, send_secret}`. Duplicate tokens are permitted for separate machines.
  Only SHA-256 of the 32-byte base64url secret is stored; retain the returned secret.
- `DELETE /v1/handles/:handle`: bearer secret; returns `204`, unknown handle `404`.
- `POST /v1/send`: bearer secret and JSON `{v:1, handle, push_class, ttl_s,
  collapse_token?, sealed, kid, idempotency_key, fallback}`. Classes are `alert_high`
  or `alert_normal`; TTL is 0–2419200 seconds. Returns `202 {"status":"accepted"}`
  once a supervised in-process delivery task is admitted, before provider delivery.
  Concurrent retries with the same handle/key return the original HTTP status without
  another delivery for 24 hours. Unknown fields are ignored.

Bad secrets return `401`; unknown handles `404`; provider-invalidated handles `410`;
request bodies above 8192 bytes or sealed values above 3400 bytes `413`; invalid
schemas `422`; fallback mismatch `422 {"error":"fallback_mismatch"}`. Store or queue
failure returns `503`. Providers receive only the configured fallback pin. No other
clear alert text is forwarded.

The store retains metadata-only send logs (handle/time/size/status) for seven days,
and idempotency rows for 24 hours. Pruning runs on acceptance and every ten minutes.
The `sends.delivery` column records provider outcomes (`delivered`, `gone`, `retry`,
`error`); HTTP acceptance remains `202`. Retry scheduling is not supplied here.
Accepted payloads are held in memory only: a process or service restart can lose an
accepted delivery; this is not a durable delivery queue. Provider errors and exceptions
are contained and logged using only handle, status and size, never provider reasons,
sealed content, push tokens or bearer secrets. Real provider credentials and TLS
termination belong to deployment; do not expose this skeleton publicly without the
abuse-control and deployment work.

For HTTP tests, set `:fake_owner` to the test process when configuring `Provider.Fake`.
It sends `{:delivery, task_pid, handle_row, envelope}` to that process and waits up to
2 seconds for `{:result, provider_result}` (default `:ok`). The fixture also accepts
`{:result, :raise}` to exercise exception redaction. These application settings are
for isolated test runs; they are not credentials or a production provider.

## FCM HTTP v1

When configured, FCM exchanges a service-account RS256 JWT for a Firebase Messaging OAuth token and refreshes the cached token five minutes before expiry. Each send is data-only: `data` contains the sealed value, key id and protocol version; the request never includes a `notification` block. Android priority follows `push_class` (`alert_high` → `HIGH`, otherwise `NORMAL`), TTL is sent as seconds (for example `3600s`), and collapse key is `a` for `alert_high` or `b` for `alert_normal`. FCM does not receive the envelope's APNs `collapse_token`.

FCM `UNREGISTERED` marks a handle gone; quota errors retry after the provider's `Retry-After` value or 60 seconds; server and transport failures retry after 60 seconds; invalid arguments are recorded with the `INVALID_ARGUMENT` code but no response body. A serialized outbound message over 4,096 bytes is rejected before token exchange or send. `/healthz` includes `fcm: ok`, `unconfigured`, or `degraded` without exposing credential details.

The cross-platform push contract §5 source is not present in this checkout. This README records the relay's selected FCM behavior, including the two-key collapse mapping; the authoritative contract should carry the same detail when its source repository is available.

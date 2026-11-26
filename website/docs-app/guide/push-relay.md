# Push relay

The standalone relay in `packages/aiur-push-relay` accepts opaque sealed notifications
and sends APNs alerts over HTTP/2. Deploy it separately from the daemon. Configure TLS
before exposing the relay publicly.

## Apple credentials

Set these in the relay process environment, then restart the relay:

| Variable | Value | Default |
| --- | --- | --- |
| `AIUR_RELAY_APNS_TEAM_ID` | Apple developer team ID | None |
| `AIUR_RELAY_APNS_KEY_ID` | APNs signing key ID | None |
| `AIUR_RELAY_APNS_KEY_FILE` | Path to the P-256 `.p8` private key, file mode `0600` | None |

Missing, unreadable, invalid or incorrectly permissioned credentials disable APNs.
`GET /healthz` then reports `"apns":"unavailable"`; APNs handle registration returns
`503 provider_unavailable`. Store health still determines the health endpoint's HTTP
status. FCM registration is unavailable until its service account is configured.

Configure `AIUR_RELAY_APP_TOPICS` and a JSON fallback pin in
`AIUR_RELAY_FALLBACK_<APP_TOPIC_SLUG>` for each topic. The relay uses that pin for
every visible alert and never uses caller-supplied alert text. Full startup and HTTP
examples are in the package README.

The handle environment selects Apple's sandbox or production host. Provider JWTs
refresh every 40 minutes; an expired-token response triggers one refresh and retry.
Unregistered or invalid device tokens mark the handle gone, making later sends return
`410`.

Throttling returns a 60-second retry hint; transport and server failures return
a 5-second hint. Retry scheduling is not yet supplied by this package.

Apple sandbox acceptance with real credentials is a separate deployment check.
Keep signing keys outside Git and do not expose tokens or sealed content in logs.

## Firebase credentials

Set `AIUR_RELAY_FCM_SERVICE_ACCOUNT_FILE` to a Firebase service-account JSON file with no
group or world permissions, then restart the relay. Keep the file outside Git and restrict
access to the relay process.

Missing credentials report `"fcm":"unconfigured"`; invalid credentials report
`"fcm":"degraded"`. Handle registration and sends return `503 provider_unavailable`
until credentials load.

FCM sends sealed data only, without notification text. Priority and TTL follow the envelope;
unregistered tokens mark the handle gone.

## Abuse limits

Limits use persistent SQLite token buckets and are applied per handle or source IP:

| Environment variable | Default | Behavior |
| --- | ---: | --- |
| `AIUR_RELAY_SEND_PER_HOUR` | `60` | Send tokens refilled per handle per hour |
| `AIUR_RELAY_SEND_BURST` | `10` | Maximum immediate sends per handle |
| `AIUR_RELAY_HANDLES_PER_IP_HOUR` | `20` | Handle creation burst and refill per source IP |
| `AIUR_RELAY_LOG_RETENTION_DAYS` | `7` | Metadata-only send-log retention; values above `7` prevent startup |

An exhausted limit returns HTTP `429` with `{"error":"rate_limited","retry_after_s":N}`
and a `Retry-After` header. Replaying an accepted idempotency key does not use another
send token. If SQLite is unavailable, requests fail closed with `503`.

Request bodies are limited to 8 KiB, push tokens to 4 KiB, and sealed envelopes to 3,400
bytes. Idempotency rows expire after 24 hours. Send logs contain only the handle, time,
size, and status, and expire within the configured retention period (at most seven days).

## Relay settings

| Environment variable | Meaning |
| --- | --- |
| `AIUR_RELAY_APP_TOPICS` | Required comma-separated allowed app IDs |
| `AIUR_RELAY_FALLBACK_<APP_TOPIC_SLUG>` | Required pinned fallback JSON for each app ID |
| `AIUR_RELAY_DATABASE` | SQLite database path; defaults to `relay.sqlite3` |
| `AIUR_RELAY_PORT` | HTTP port; defaults to `4001` |

Fallback values use `{"title":"Aiur","body":"Open Aiur"}` and the combined title and
body must fit within 200 UTF-8 bytes. The relay rejects registrations for app IDs without
a configured fallback.

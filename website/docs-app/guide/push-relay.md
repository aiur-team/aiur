# Push relay operations

The reference push relay is a standalone service in `packages/aiur-push-relay`. It stores
handle credentials and delivery metadata in SQLite. Keep the database persistent across
restarts and restrict access to the relay; it is not the inbound Cloudflare tunnel used by
the Aiur dashboard.

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

## Existing relay settings

| Environment variable | Meaning |
| --- | --- |
| `AIUR_RELAY_APP_TOPICS` | Required comma-separated allowed app IDs |
| `AIUR_RELAY_FALLBACK_<APP_TOPIC_SLUG>` | Required pinned fallback JSON for each app ID |
| `AIUR_RELAY_DATABASE` | SQLite database path; defaults to `relay.sqlite3` |
| `AIUR_RELAY_PORT` | HTTP port; defaults to `4001` |

Fallback values use `{"title":"Aiur","body":"Open Aiur"}` and the combined title and
body must fit within 200 UTF-8 bytes. The relay rejects registrations for app IDs without
a configured fallback.

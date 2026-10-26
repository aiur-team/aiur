# Outbound events

Aiur can push ticket lifecycle, progress, usage, spend-cap and cancellation
results to a TypeScript service over signed webhooks. Consumers do not poll.
The first release supports one webhook endpoint per Aiur instance.

## Configure delivery

Set a 256-bit signing secret outside the repository:

```sh
printf 'AIUR_OUTBOUND_WEBHOOK_SECRET=whsec_%s\n' "$(openssl rand -base64 32 | tr -d '\n')" >> ~/.aiur/.env
```

Then enable the exporter in `.aiur/config`:

```yaml
events:
  export:
    enabled: true
    webhook_url: https://consumer.example.com/webhooks/aiur
    allow_private_destinations: false
    # subject_id: "5695"       # optional exact ticket or job ID
    max_pending_events: 10000
    retry_ms: 5000
    request_timeout_ms: 15000
```

Aiur refuses startup when export is enabled without a correctly formed secret.
The URL must use HTTPS and cannot contain userinfo or a fragment. Redirects are
not followed, so the signed body is sent only to the configured origin.

By default, literal and DNS-resolved loopback, link-local, metadata, RFC1918,
CGNAT, ULA, and unspecified addresses are rejected. Aiur resolves the host for
every attempt and pins the connection to the validated address, while retaining
the original hostname for TLS and the Host header.

Set `allow_private_destinations: true` only for a trusted development or
intranet receiver.

## Verify before parsing

Every request carries the Standard Webhooks headers `webhook-id`,
`webhook-timestamp` and `webhook-signature`. Verify the signature against the
exact raw body before parsing JSON. Verification rejects timestamps outside the
five-minute window.

Atomically claim `webhook-id` in durable storage before processing it to reject
a replay inside that window and to make at-least-once delivery idempotent.
The ID is `<instance>/<id>` and must match those two fields in the signed body.

The independently installable `@aiur/contracts` package includes versioned JSON
Schemas, generated TypeScript types, golden fixtures, and an executable
[`webhook-receiver.ts`](https://github.com/aiur-team/aiur/blob/main/packages/aiur-contracts/examples/webhook-receiver.ts)
example using the official `standardwebhooks` package.

Its in-memory ID store is for local examples only; production receivers need a
durable atomic store.

## Event envelope

All events use the same canonical identifier-only envelope: `v`, `instance`,
`seq`, `id`, `topic`, `class`, `occurred_at`, `observed_at`, `source`, `refs`,
`attrs`, `payload_version`, and the reserved `anchor`. `seq` is the dense export
order; `(instance, id)` is the event identity and is not an ordering cursor.
Ticket and job correlation are `refs.ticket` and `refs.job_id`; a configured
`subject_id` matches either value exactly.

| Event | Topic family |
| --- | --- |
| Ticket lifecycle | `ticket.<id>.lifecycle.changed` |
| Ticket progress | `ticket.<id>.agent.progress`, `.progress.checkin`, or `.progress.phase` |
| Ticket usage | `ticket.<id>.usage.changed` |
| Spend-cap transition | `ticket.<id>.usage.spend_cap_reached` |
| Cancellation result | `ticket.<id>.cancel.result` |

Each family has a separate v1 JSON Schema constraining its topic, references,
and attributes, while the shared envelope is built by the event bus. Treat an
event as a refresh signal and re-read the owning API for authoritative state.
Unknown topics or newer `v` values require a newer contract package; a breaking
wire change adds another schema version instead of changing v1 in place.

## Retry and queue behavior

Aiur persists an exportable event before attempting delivery. Transport errors,
redirects, 408, 429, and 5xx responses leave the durable cursor unchanged and
retry the identical event body with capped exponential backoff and jitter.

A 2xx response acknowledges it. Other 4xx responses are permanent: Aiur raises a
needs-attention alert, advances past that event, and continues the queue.

Internal event publication is fail-open. Non-exportable topics bypass the
export journal; exportable topics receive a short durability budget so a slow
disk cannot stall orchestration. A journal timeout or admission failure is
reported and the internal event still fans out.

The queue is bounded by `max_pending_events`. A full queue never evicts pending
events and raises a needs-attention alert. The alert resolves after acknowledged
records are compacted and admission resumes. Queue files and logs never include
the signing secret or the webhook URL query.

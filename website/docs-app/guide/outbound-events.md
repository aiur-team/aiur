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
    # subject_id: "5695"       # optional exact ticket or job ID
    max_pending_events: 10000
    retry_ms: 5000
    request_timeout_ms: 15000
```

Aiur refuses startup when export is enabled without a correctly formed secret.
The URL must use HTTPS and cannot contain userinfo or a fragment. Redirects are
not followed, so the signed body is sent only to the configured origin.

## Verify before parsing

Every request carries the Standard Webhooks headers `webhook-id`,
`webhook-timestamp` and `webhook-signature`. Verify the signature against the
exact raw body before parsing JSON. Verification rejects timestamps outside the
five-minute window.

Atomically claim `webhook-id` in durable storage before processing it to reject
a replay inside that window and to make at-least-once delivery idempotent.

The independently installable `@aiur/contracts` package includes versioned JSON
Schemas, generated TypeScript types, golden fixtures, and an executable
[`webhook-receiver.ts`](https://github.com/aiur-team/aiur/blob/main/packages/aiur-contracts/examples/webhook-receiver.ts)
example using the official `standardwebhooks` package.

Its in-memory ID store is for local examples only; production receivers need a
durable atomic store.

## Event envelope

All events include `contract`, `contract_version`, `event_id`, `event_type`,
`emitted_at`, and `ticket_id`; run events also include `job_id`, and a
configured `subject_id` matches either identifier exactly.

| Event | Contract |
| --- | --- |
| Ticket lifecycle | `aiur.ticket_lifecycle_event` v1 |
| Ticket progress | `aiur.ticket_progress_event` v1 |
| Ticket usage | `aiur.ticket_usage_event` v1 |
| Spend-cap transition | `aiur.spend_cap_event` v1 |
| Cancellation result | `aiur.cancel_result_event` v1 |

Treat additive fields and unknown event types as forward-compatible. A breaking
wire change adds another schema version instead of changing v1 in place.

## Retry and queue behavior

Aiur persists an event before attempting delivery. A transport failure,
redirect, or non-2xx response leaves the durable cursor unchanged and retries
the identical event body. Only a 2xx response acknowledges it.

The queue is bounded by `max_pending_events`. A full queue never evicts pending
events and raises a needs-attention alert. The alert resolves after acknowledged
records are compacted and admission resumes. Queue files and logs never include
the signing secret or the webhook URL query.

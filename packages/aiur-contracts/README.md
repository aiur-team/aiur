# @aiur/contracts

Versioned wire contracts for Aiur clients, packaged independently from the
daemon. It can be installed from a release tarball or published to a package
registry without the Aiur repository. The main contract entrypoint is
dependency-free; the optional webhook receiver entrypoint uses the official
`standardwebhooks` package declared as a runtime dependency.
The v1 schemas use JSON Schema draft 2020-12. They cover capabilities, the
CLI and HTTP status surfaces, per-ticket usage, per-ticket progress, ticket
spend caps, and outbound ticket events. Snapshot clients ignore unknown IDs
and additive fields. Outbound event schemas are identifier-only allowlists;
a breaking event-envelope change adds v2 beside v1.

Capability `mode` now accepts any string so merge policy can report `ci=wait local_tests=partial`.
The former `in_band_hold`, `defer_resume` and `none` values remain valid, but generated TypeScript
consumers lose the closed union and must handle unknown modes when switching on this field.

`src/index.ts` exports generated `CapabilitiesReport`, `CapabilityEntry`,
`CapabilityState`, `CapabilityReason`, `CapabilityError`, `AgentsStatus`,
`FleetStatus`, `TicketStatus`, `TicketCancel`, `TicketUsage`, `TicketProgress`,
`TicketSpendCap`, `TicketSpendCapReached`, and `OutboundEvent` types,
`KNOWN_CAPABILITY_IDS`, `KNOWN_CAPABILITY_ID_PATTERNS`, and `CAPABILITY_REASONS`.
Harness patterns accept one lowercase `[a-z0-9_]+` segment.
Run `npm run build` before importing runtime constants from this local package.
Schemas are also available through `@aiur/contracts/schemas/*`.

| Schema and fixture stem | Live producer | Contract |
| --- | --- | --- |
| `agents.v1` | `aiur agents --json` | `aiur.agents` |
| `status.v1` | `GET /api/v1/state` | `aiur.status` |
| `ticket.v1` | `GET /api/v1/:id` | `aiur.ticket` |
| `ticket-cancel.v1` | `POST /api/v1/:id/cancel` | `aiur.ticket_cancel` |
| `ticket-usage.v1` | `GET /api/v1/:id/usage` and `aiur ticket-usage --json` | `aiur.ticket_usage` |
| `ticket-progress.v1` | `GET /api/v1/:id/progress` | `aiur.ticket_progress` |
| `ticket-lifecycle-event.v1` | outbound webhook | canonical envelope v1; `ticket.*.lifecycle.changed` |
| `ticket-progress-event.v1` | outbound webhook | canonical envelope v1; `ticket.*.agent.progress*` |
| `ticket-usage-event.v1` | outbound webhook | canonical envelope v1; `ticket.*.usage.changed` |
| `ticket-spend-cap-reached-event.v1` | outbound webhook | canonical envelope v1; `ticket.*.usage.spend_cap_reached` |
| `ticket-cancel-result-event.v1` | outbound webhook | canonical envelope v1; `ticket.*.cancel.result` |
| `ticket-spend-cap.v1` | `GET /api/v1/:id/spend-cap` | `aiur.ticket_spend_cap` |
| `ticket-spend-cap-reached.v1` | `ticket.<id>.usage.spend_cap_reached` | `aiur.ticket_spend_cap_reached` |

New consumer contracts follow the same layout: a schema and golden fixture with
the same `<surface>.vN` stem and an exported type in one of the generated
contract unions. Snapshot contracts use top-level `contract` and
`contract_version`; outbound signals use the shared `v`, `payload_version`,
`topic`, `refs`, and `attrs` envelope.

```sh
npm ci
npm run generate # after editing schemas
npm run check    # generation drift, fixture schema and type checks, type check
npm test
npm run pack:check # install the tarball in an isolated TypeScript consumer
```

## Receiving signed events

Aiur signs the exact raw request body with the Standard Webhooks headers
`webhook-id`, `webhook-timestamp`, and `webhook-signature`. Verify the raw body
before parsing it, then atomically claim `webhook-id` in durable storage before
processing the event. The official `standardwebhooks` package enforces the
signature and five-minute timestamp window; ID storage prevents a valid request
from being replayed inside that window.

`webhook-id` is `<instance>/<id>`. The body repeats `instance` and `id`, while
the export journal's dense `seq` is the delivery order. Ticket and job
correlation live under `refs`; bounded enums and counters live under `attrs`.
The event is a refresh signal, so fetch authoritative state from the owning API
instead of treating the signal as a snapshot.

[`examples/webhook-receiver.ts`](examples/webhook-receiver.ts) is an executable
TypeScript example and is published as `@aiur/contracts/webhook-receiver`. Its
in-memory ID store is for tests and local examples only; a deployed receiver
must provide a durable atomic implementation.

The golden fixtures bridge Node validation and the daemon's actual wire encoders.
From the repository root, regenerate them explicitly with:

```sh
(cd src && AIUR_UPDATE_GOLDEN=1 mise exec -- mix test --max-cases 4 \
  test/aiur/capabilities_wire_test.exs test/aiur/status_contracts_golden_test.exs)
npm --prefix packages/aiur-contracts run generate
npm --prefix packages/aiur-contracts run check
npm --prefix packages/aiur-contracts test
```

Ordinary tests never write fixtures. Review fixture and type changes together.
The refusal fixture describes the shared 409/503 capability error envelope.
`retention` remains opaque here; the event export contract owns its shape.

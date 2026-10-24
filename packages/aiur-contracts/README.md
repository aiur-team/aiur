# @aiur/contracts

Private, unpublished wire contracts for Aiur clients. No runtime dependencies.
The v1 schemas use JSON Schema draft 2020-12. They cover capabilities, the
CLI and HTTP status surfaces, per-ticket usage, and per-ticket progress.
Clients ignore unknown IDs and additive fields. A breaking change adds v2 beside v1.

Capability `mode` now accepts any string so merge policy can report `ci=wait local_tests=partial`.
The former `in_band_hold`, `defer_resume` and `none` values remain valid, but generated TypeScript
consumers lose the closed union and must handle unknown modes when switching on this field.

`src/index.ts` exports generated `CapabilitiesReport`, `CapabilityEntry`,
`CapabilityState`, `CapabilityReason`, `CapabilityError`, `AgentsStatus`,
`FleetStatus`, `TicketStatus`, `TicketUsage`, and `TicketProgress` types,
`KNOWN_CAPABILITY_IDS`, `KNOWN_CAPABILITY_ID_PATTERNS`, and `CAPABILITY_REASONS`.
Harness patterns accept one lowercase `[a-z0-9_]+` segment.
Run `npm run build` before importing runtime constants from this local package.
Schemas are also available through `@aiur/contracts/schemas/*`.

| Schema and fixture stem | Live producer | Contract |
| --- | --- | --- |
| `agents.v1` | `aiur agents --json` | `aiur.agents` |
| `status.v1` | `GET /api/v1/state` | `aiur.status` |
| `ticket.v1` | `GET /api/v1/:id` | `aiur.ticket` |
| `ticket-usage.v1` | `GET /api/v1/:id/usage` and `aiur ticket-usage --json` | `aiur.ticket_usage` |
| `ticket-progress.v1` | `GET /api/v1/:id/progress` | `aiur.ticket_progress` |

New consumer contracts follow the same layout: a schema and golden fixture with
the same `<surface>.vN` stem, a top-level `contract` and `contract_version`, and
an exported type in one of the generated contract unions.

```sh
npm ci
npm run generate # after editing schemas
npm run check    # generation drift, fixture schema and type checks, type check
npm test
```

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

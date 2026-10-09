# @aiur/contracts

Private, unpublished wire contracts for Aiur clients. No runtime dependencies.
The v1 schemas use JSON Schema draft 2020-12. Capability IDs are free-form;
clients ignore unknown IDs and additive fields. A breaking change adds v2 beside v1.

`src/index.ts` exports generated `CapabilitiesReport`, `CapabilityEntry`,
`CapabilityState`, `CapabilityReason`, and `CapabilityError` types,
`KNOWN_CAPABILITY_IDS`, `KNOWN_CAPABILITY_ID_PATTERNS`, and `CAPABILITY_REASONS`.
Harness patterns accept one lowercase `[a-z0-9_]+` segment.
Run `npm run build` before importing runtime constants from this local package.
Schemas are also available through `@aiur/contracts/schemas/*`.

```sh
npm ci
npm run generate # after editing schemas
npm run check    # generation drift, fixture validation, type check
npm test
```

The golden fixture bridges Node validation and the daemon's actual wire encoder.
From the repository root, regenerate it explicitly with:

```sh
(cd src && AIUR_UPDATE_GOLDEN=1 mise exec -- mix test --max-cases 4 test/aiur/capabilities_wire_test.exs)
npm --prefix packages/aiur-contracts run generate
npm --prefix packages/aiur-contracts run check
npm --prefix packages/aiur-contracts test
```

Ordinary tests never write fixtures. Review fixture and type changes together.
The refusal fixture describes the shared 409/503 capability error envelope.
`retention` remains opaque here; the event export contract owns its shape.

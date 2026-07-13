# Standalone Dashboard Companion Tickets

These twenty-five tickets implement the capability delta between current OCC
main and the refreshed prototype. They are intentionally not members,
completion requirements, or ETA inputs of the Build Order root.

| ID | Outcome | Cx | Hard prerequisites |
|---|---|---:|---|
| [DASH-001](companion-tickets/DASH-001-responsive-route-shell.md) | Responsive route-aware shell | 3 | BO-008 |
| [DASH-002](companion-tickets/DASH-002-current-run-membership.md) | Recoverable current-run membership | 4 | BO-017 |
| [DASH-016](companion-tickets/DASH-016-units-row-policy.md) | Canonical Units rows, predicates, counts, and URL policy | 3 | DASH-002, BO-005 |
| [DASH-003](companion-tickets/DASH-003-units-interface.md) | Responsive Units filters/table | 3 | DASH-001, DASH-016, BO-018 |
| [DASH-004](companion-tickets/DASH-004-applied-unit-control-protocol.md) | Worker-applied pause/resume protocol | 4 | — |
| [DASH-005](companion-tickets/DASH-005-unit-capacity-controls-ui.md) | Unit and positive-capacity controls | 3 | DASH-003, DASH-004 |
| [DASH-006](companion-tickets/DASH-006-decision-lookup.md) | Retained Decision lookup/query contract | 3 | — |
| [DASH-017](companion-tickets/DASH-017-decision-provenance.md) | Trusted Decision provenance; unchanged supervisor confidence | 3 | — |
| [DASH-007](companion-tickets/DASH-007-commands-interface.md) | Commands presentation catch-up | 3 | DASH-001, DASH-006, DASH-017 |
| [DASH-018](companion-tickets/DASH-018-provider-account-generation.md) | Shared opaque provider-account generation | 3 | — |
| [DASH-008](companion-tickets/DASH-008-usage-envelope.md) | Provider-neutral usage envelopes | 4 | BO-017, DASH-018 |
| [DASH-009](companion-tickets/DASH-009-durable-usage-ledger.md) | Canonical raw append/delta/replay ledger | 4 | DASH-008 |
| [DASH-024](companion-tickets/DASH-024-usage-aggregate-query.md) | Crash-safe usage aggregate/query projection | 4 | DASH-009 |
| [DASH-025](companion-tickets/DASH-025-usage-retention-compaction.md) | Rotation/retention/compaction hardening | 4 | DASH-024 |
| [DASH-011](companion-tickets/DASH-011-cost-grouping-projection.md) | Versioned cost/grouping projection | 4 | DASH-024 |
| [DASH-019](companion-tickets/DASH-019-claude-telemetry-transport.md) | Authenticated bounded Claude telemetry transport | 4 | `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` |
| [DASH-010](companion-tickets/DASH-010-claude-remote-usage.md) | Required Claude Remote usage adapter | 3 | DASH-008, DASH-019 |
| [DASH-012](companion-tickets/DASH-012-provider-meter-foundation.md) | Provider-meter snapshot/LKG foundation | 3 | DASH-018 |
| [DASH-020](companion-tickets/DASH-020-codex-provider-meter-adapter.md) | Codex meter and scheduling adapter | 3 | DASH-012 |
| [DASH-013](companion-tickets/DASH-013-claude-provider-meters.md) | Claude subscription/API meter parity | 4 | DASH-012; `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` |
| [DASH-014](companion-tickets/DASH-014-current-run-summary.md) | Canonical current-run summary | 4 | DASH-016 |
| [DASH-021](companion-tickets/DASH-021-financial-data-auth-boundary.md) | Enforced financial-data web boundary | 3 | DASH-001 |
| [DASH-022](companion-tickets/DASH-022-current-run-summary-ui.md) | Accessible nonfinancial run-summary UI | 3 | DASH-003, DASH-014 |
| [DASH-015](companion-tickets/DASH-015-usage-provider-summary-ui.md) | Authenticated usage/provider summary UI | 4 | DASH-003, DASH-010, DASH-011, DASH-013, DASH-020, DASH-021, DASH-025 |
| [DASH-023](companion-tickets/DASH-023-selected-build-order-usage.md) | Selected Build Order usage integration | 4 | BO-003, BO-012, DASH-011, DASH-015, DASH-021 |

Total: 25 tickets, 87 complexity points.

## Why twenty-five

- Recoverable current-run membership is a durable state owner; rich Units rows,
  predicates, counts, and URL policy are a separate pure read-model contract.
- Runtime control request acceptance is not worker application; the protocol
  must exist before toggle UI can claim success.
- Retained Decision lookup/query behavior is independent from trusted durable
  provenance schema and migration. Both serialize on shared store surfaces
  without a false semantic dependency, while existing integer `0..100`
  supervisor confidence remains unchanged.
- Privacy-safe provider-account identity is shared infrastructure, not usage-
  or meter-local state.
- Measurement normalization, raw append/delta/replay, aggregate/query recovery,
  destructive retention/compaction, authenticated Claude telemetry transport,
  Remote event mapping, and cost projection have distinct trust, storage,
  protocol, and review boundaries.
- The provider-meter contract precedes Codex and Claude adapters, allowing the
  two provider integrations to proceed in parallel.
- Financial-data authorization must prevent queries/subscriptions/assigns
  before presentation; hiding values in UI is insufficient.
- The nonfinancial Aiur run summary can ship independently from protected
  provider usage and account-meter cards.
- Selected Build Order usage is a cross-source live integration over current
  GitHub membership, not a concern to hide inside the Units-default summary or
  the Build Order feature's own acceptance.

The complete evidence matrix is
[06-prototype-capability-audit.md](06-prototype-capability-audit.md).

## Scheduling and shared surfaces

- Every companion is non-pickable until
  `GATE-OCC-PREDECESSOR-BASELINE` records that the bounded predecessor run is
  complete and the configured implementation branch contains its accepted
  successors. Publication is allowed before resolution because it adds no
  dispatch label.
- DASH-001 owns shared route/navigation/CSS metadata and consumes BO-008's
  Phoenix/LiveView browser harness. Closed #1034 is accepted predecessor
  evidence, not a new native blocker.
- DASH-002 and DASH-008 consume BO-017 propagated identity; DASH-002 owns only
  membership/recovery. DASH-004 and DASH-019 depend on BO-004's canonical
  configured-repository identity before issuing controls or correlating
  telemetry.
  DASH-016 joins BO-005 activity and owns all Units rows/predicates/counts/URL
  policy. DASH-003 consumes BO-018's accessible reusable base context rather
  than building a second modal; BO-011 remains Build Order-specific.
- DASH-003/005/007/015/021/022/023 and BO-012..014 touch shared dashboard,
  authentication, or CSS surfaces and must follow typed serialization edges.
  Same-pack edges are symmetric; cross-pack edges are declared by companions
  because the standalone core manifest cannot reference DASH IDs. DASH-001
  serializes with BO-012, and DASH-023 serializes with BO-013/014 while its
  dependency already orders it after BO-012. DASH-015/023 are hard-ordered;
  DASH-022 serializes with each on the shared summary layout.
- DASH-006 and DASH-017 `serialize_with` each other on Decision store/schema
  files. DASH-006 owns read/query behavior; DASH-017 owns durable trusted
  fields and migration.
- DASH-018 solely owns the opaque provider-account generation shared by usage
  and meters. DASH-008/012 consume it, and provider adapters only report
  trusted lifecycle evidence. DASH-018/019 serialize on the shared Claude
  process-lifecycle adapter; DASH-019 still owns only telemetry launch,
  producer authentication, and session correlation.
- DASH-008 serializes with BO-005's event migration. DASH-009 owns raw append,
  counter delta, checkpoint and replay; DASH-024 owns aggregate/query recovery;
  DASH-025 alone owns destructive rotation/retention/compaction and preserves
  every grouping dimension before deletion.
- DASH-011 exposes generation-qualified groups but does not join meter data.
  DASH-015 alone joins tier facts by provider, backend, and exact known
  generation, with explicit unknown/mixed/mismatch states.
- DASH-019 owns secure local Claude transport/correlation and its protocol gate;
  DASH-010 owns only authenticated event-to-envelope mapping. Its BO-004
  prerequisite supplies repository-qualified ticket correlation and does not
  transfer telemetry ownership to the Build Order graph.
- DASH-012 owns the generic meter/LKG contract. DASH-020 and DASH-013 can run in
  parallel after it.
- DASH-021 owns protected query/subscription delivery. DASH-022 receives only
  nonfinancial DASH-014 facts; DASH-015 receives protected values only through
  DASH-021. Provider/backend/model is protected only inside financial records;
  unauthenticated read-only Units retains nonfinancial StatusReport execution
  backend/model.
- DASH-023 combines BO-003's exact current member generation with DASH-011's
  explicit-ticket query on BO-012's URL-backed route. It includes retained
  pre-membership observations, excludes removed tickets, and never changes
  Build Order membership, progress, ETA, readiness, or acceptance.
- DASH-019/013 are not dispatchable until their named human-owned protocol gate
  has a resolution receipt. Their Aiur issues remain incomplete while a
  required external contract is blocked.

## External gates

These gates record predecessor, authority, and protocol evidence. A provider
gate resolves with an evidenced Aiur-only path or an already-landed pinned
compatible sibling revision. Missing sibling capability requires a separately
authorized sibling issue/PR that lands first; DASH-013/019 never implement or
test unlanded sibling changes. Until every referenced gate resolves, a ticket
is not pickable.

| Gate | Human owner | Resolution receipt |
|---|---|---|
| `GATE-OCC-PREDECESSOR-BASELINE` | Product owner and current OCC Executor | Bounded predecessor run is complete; configured implementation branch and SHA contain closed #1034 plus all accepted OCC successors |
| `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` | Human owner with `aiur-claude` write authority | Reviewed matrix plus secure Aiur-only path or already-landed pinned compatible sibling revision; otherwise separate sibling issue/PR lands first |
| `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` | Human owner with `aiur-claude` write authority | Reviewed matrix plus existing source or already-landed pinned compatible sibling revision; otherwise separate sibling issue/PR lands first |

## Existing-work disposition

- DASH-009/024/025 supersede #132's storage/accounting contract. The proposed
  opencode TUI surface stays separate and is recorded in the deferred ledger.
- DASH-009/024/025/011 relate to #845, but this bounded local-first program does not
  pull in its Postgres/multi-controller/BI scope.
- Debug-only #930 is evidence, not normal-run accounting truth.
- Closed #1033 documents the current dashboard; these companions own
  documentation for their future behavior.

## Publication

Create these as standalone issues with one exact `complexity:N` and
`model:codex`. Every issue also carries the non-native predecessor gate in its
contract and no dispatch label. Publish the hard prerequisites above as native
blockers, including cross-scope BO edges, but add no Build Order parent,
phase/lane, or active `agent:*` label. Returned identities and full observed
labels live in `dashboard-companions.json`.

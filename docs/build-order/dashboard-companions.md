# Standalone Dashboard Companion Tickets

These twenty-two tickets implement the capability delta between current OCC
main and the refreshed prototype. They are intentionally not members,
completion requirements, or ETA inputs of the Build Order root.

| ID | Outcome | Cx | Hard prerequisites |
|---|---|---:|---|
| [DASH-001](companion-tickets/DASH-001-responsive-route-shell.md) | Responsive route-aware shell | 3 | BO-008 |
| [DASH-002](companion-tickets/DASH-002-current-run-membership.md) | Recoverable current-run membership | 4 | BO-004 |
| [DASH-016](companion-tickets/DASH-016-units-row-policy.md) | Canonical Units rows, predicates, counts, and URL policy | 3 | DASH-002, BO-005 |
| [DASH-003](companion-tickets/DASH-003-units-interface.md) | Responsive Units filters/table | 3 | DASH-001, DASH-016, BO-016 |
| [DASH-004](companion-tickets/DASH-004-applied-unit-control-protocol.md) | Worker-applied pause/resume protocol | 4 | — |
| [DASH-005](companion-tickets/DASH-005-unit-capacity-controls-ui.md) | Unit and positive-capacity controls | 3 | DASH-003, DASH-004 |
| [DASH-006](companion-tickets/DASH-006-decision-lookup.md) | Retained Decision lookup/query contract | 3 | — |
| [DASH-017](companion-tickets/DASH-017-decision-provenance.md) | Trusted Decision provenance/confidence | 3 | — |
| [DASH-007](companion-tickets/DASH-007-commands-interface.md) | Commands presentation catch-up | 3 | DASH-001, DASH-006, DASH-017 |
| [DASH-018](companion-tickets/DASH-018-provider-account-generation.md) | Shared opaque provider-account generation | 3 | — |
| [DASH-008](companion-tickets/DASH-008-usage-envelope.md) | Provider-neutral usage envelopes | 4 | BO-004, DASH-018 |
| [DASH-009](companion-tickets/DASH-009-durable-usage-ledger.md) | Durable attributed usage ledger | 4 | DASH-008 |
| [DASH-011](companion-tickets/DASH-011-cost-grouping-projection.md) | Versioned cost/grouping projection | 4 | DASH-009 |
| [DASH-019](companion-tickets/DASH-019-claude-telemetry-transport.md) | Authenticated bounded Claude telemetry transport | 4 | `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` |
| [DASH-010](companion-tickets/DASH-010-claude-remote-usage.md) | Required Claude Remote usage adapter | 3 | DASH-008, DASH-019 |
| [DASH-012](companion-tickets/DASH-012-provider-meter-foundation.md) | Provider-meter snapshot/LKG foundation | 3 | DASH-018 |
| [DASH-020](companion-tickets/DASH-020-codex-provider-meter-adapter.md) | Codex meter and scheduling adapter | 3 | DASH-012 |
| [DASH-013](companion-tickets/DASH-013-claude-provider-meters.md) | Claude subscription/API meter parity | 4 | DASH-012; `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` |
| [DASH-014](companion-tickets/DASH-014-current-run-summary.md) | Canonical current-run summary | 4 | DASH-016 |
| [DASH-021](companion-tickets/DASH-021-financial-data-auth-boundary.md) | Enforced financial-data web boundary | 3 | DASH-001 |
| [DASH-022](companion-tickets/DASH-022-current-run-summary-ui.md) | Accessible nonfinancial run-summary UI | 3 | DASH-003, DASH-014 |
| [DASH-015](companion-tickets/DASH-015-usage-provider-summary-ui.md) | Authenticated usage/provider summary UI | 4 | DASH-003, DASH-010, DASH-011, DASH-013, DASH-020, DASH-021 |

Total: 22 tickets, 75 complexity points.

## Why twenty-two

- Recoverable current-run membership is a durable state owner; rich Units rows,
  predicates, counts, and URL policy are a separate pure read-model contract.
- Runtime control request acceptance is not worker application; the protocol
  must exist before toggle UI can claim success.
- Retained Decision lookup/query behavior is independent from trusted durable
  provenance/confidence schema and migration. Both serialize on shared store
  surfaces without a false semantic dependency.
- Privacy-safe provider-account identity is shared infrastructure, not usage-
  or meter-local state.
- Measurement normalization, durability, authenticated Claude telemetry
  transport, Remote event mapping, and cost projection have distinct trust,
  storage, protocol, and review boundaries.
- The provider-meter contract precedes Codex and Claude adapters, allowing the
  two provider integrations to proceed in parallel.
- Financial-data authorization must prevent queries/subscriptions/assigns
  before presentation; hiding values in UI is insufficient.
- The nonfinancial Aiur run summary can ship independently from protected
  provider usage and account-meter cards.

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
- DASH-002 consumes BO-004 typed identity and owns only membership/recovery.
  DASH-016 joins BO-005 activity and owns all Units rows/predicates/counts/URL
  policy. DASH-003 consumes BO-016 ticket context rather than building a second
  modal.
- DASH-003/005/007/015/021/022 and BO-012..014 touch shared dashboard,
  authentication, or CSS surfaces and must be sequenced or rebased. DASH-015
  and DASH-022 `serialize_with` each other on the summary container without a
  hard semantic edge.
- DASH-006 and DASH-017 `serialize_with` each other on Decision store/schema
  files. DASH-006 owns read/query behavior; DASH-017 owns durable trusted
  fields and migration.
- DASH-018 solely owns the opaque provider-account generation shared by usage
  and meters. DASH-008/012 consume it, and provider adapters only report
  trusted lifecycle evidence.
- DASH-008 serializes with BO-005's event migration. DASH-009 preserves
  occurrence-price date, currency, account generation, and every downstream
  grouping dimension through its single crash-consistency boundary.
- DASH-011 exposes generation-qualified groups but does not join meter data.
  DASH-015 alone joins tier facts by provider, backend, and exact known
  generation, with explicit unknown/mixed/mismatch states.
- DASH-019 owns secure local Claude transport/correlation and its protocol gate;
  DASH-010 owns only authenticated event-to-envelope mapping.
- DASH-012 owns the generic meter/LKG contract. DASH-020 and DASH-013 can run in
  parallel after it.
- DASH-021 owns protected query/subscription delivery. DASH-022 receives only
  nonfinancial DASH-014 facts; DASH-015 receives protected values only through
  DASH-021.
- DASH-019/013 are not dispatchable until their named human-owned protocol gate
  has a resolution receipt. Their Aiur issues remain incomplete while a
  required external contract is blocked.

## External gates

These gates record predecessor, authority, and protocol evidence without
creating or implying sibling issues. The human owner may resolve a provider
gate as `aiur_only` when reviewed fixtures prove no sibling change is needed,
or as `sibling_authorized` with the approved minimal contract and compatible
revision. Until all gates referenced by a ticket resolve, it is not pickable.

| Gate | Human owner | Resolution receipt |
|---|---|---|
| `GATE-OCC-PREDECESSOR-BASELINE` | Product owner and current OCC Executor | Bounded predecessor run is complete; configured implementation branch and SHA contain closed #1034 plus all accepted OCC successors |
| `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` | Human owner with `aiur-claude` write authority | Reviewed Claude/Aiur capability matrix plus either the secure Aiur-only launch/receiver path or explicit authority and compatible sibling protocol revision |
| `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` | Human owner with `aiur-claude` write authority | Reviewed structured meter-source matrix plus either the existing supported source or explicit authority and compatible sibling protocol revision |

## Existing-work disposition

- DASH-009 supersedes #132's storage/accounting contract. The proposed
  opencode TUI surface stays separate and is recorded in the deferred ledger.
- DASH-009/011 relate to #845, but this bounded local-first program does not
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

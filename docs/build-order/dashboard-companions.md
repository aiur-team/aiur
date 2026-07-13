# Standalone Dashboard Companion Tickets

These thirty-four tickets implement the capability delta between current OCC
main and the refreshed prototype. They are intentionally not members,
completion requirements, or ETA inputs of the Build Order root.

| ID | Outcome | Cx | Hard prerequisites |
|---|---|---:|---|
| [DASH-001](companion-tickets/DASH-001-responsive-route-shell.md) | Ship responsive route-aware shell | 3 | BO-008 |
| [DASH-002](companion-tickets/DASH-002-current-run-membership.md) | Recover canonical current-run membership | 4 | BO-017 |
| [DASH-016](companion-tickets/DASH-016-units-row-policy.md) | Project canonical Units rows and policy | 3 | DASH-002, BO-005 |
| [DASH-003](companion-tickets/DASH-003-units-interface.md) | Render responsive Units interface | 3 | DASH-001, DASH-016, BO-018 |
| [DASH-004](companion-tickets/DASH-004-applied-unit-control-protocol.md) | Confirm applied unit controls | 4 | BO-004 |
| [DASH-005](companion-tickets/DASH-005-unit-capacity-controls-ui.md) | Render applied unit controls | 3 | DASH-003, DASH-004 |
| [DASH-028](companion-tickets/DASH-028-authoritative-runtime-capacity-control.md) | Render runtime capacity control | 2 | DASH-003 |
| [DASH-026](companion-tickets/DASH-026-bounded-live-conversation-projection.md) | Project bounded live conversations | 3 | BO-017 |
| [DASH-027](companion-tickets/DASH-027-accessible-conversation-drawer.md) | Render accessible conversation drawer | 3 | DASH-003, DASH-026 |
| [DASH-006](companion-tickets/DASH-006-decision-lookup.md) | Add retained Decision lookup and queries | 3 | — |
| [DASH-017](companion-tickets/DASH-017-decision-provenance.md) | Persist trusted Decision provenance | 3 | — |
| [DASH-007](companion-tickets/DASH-007-commands-interface.md) | Align Commands presentation | 3 | DASH-001, DASH-006, DASH-017 |
| [DASH-018](companion-tickets/DASH-018-provider-account-generation.md) | Own provider-account generation identity | 3 | — |
| [DASH-008](companion-tickets/DASH-008-usage-envelope.md) | Define attributed usage envelopes | 3 | BO-017, DASH-018 |
| [DASH-029](companion-tickets/DASH-029-headless-usage-sources.md) | Normalize headless usage sources | 3 | DASH-008, BO-017, DASH-018 |
| [DASH-009](companion-tickets/DASH-009-durable-usage-ledger.md) | Persist canonical usage ledger | 4 | DASH-008 |
| [DASH-024](companion-tickets/DASH-024-usage-aggregate-query.md) | Project durable usage aggregates | 4 | DASH-009 |
| [DASH-025](companion-tickets/DASH-025-usage-retention-compaction.md) | Harden usage retention and compaction | 4 | DASH-024 |
| [DASH-011](companion-tickets/DASH-011-cost-grouping-projection.md) | Resolve exact usage pricing | 3 | DASH-008 |
| [DASH-030](companion-tickets/DASH-030-grouped-usage-scopes.md) | Project grouped usage scopes | 3 | DASH-011, DASH-024 |
| [DASH-019](companion-tickets/DASH-019-claude-telemetry-transport.md) | Authenticate Claude telemetry transport | 4 | BO-004; `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` |
| [DASH-010](companion-tickets/DASH-010-claude-remote-usage.md) | Normalize Claude Remote usage | 3 | DASH-008, DASH-019 |
| [DASH-012](companion-tickets/DASH-012-provider-meter-foundation.md) | Project canonical provider meters | 3 | DASH-018 |
| [DASH-020](companion-tickets/DASH-020-codex-provider-meter-adapter.md) | Normalize Codex account meters | 3 | DASH-012 |
| [DASH-013](companion-tickets/DASH-013-claude-provider-meters.md) | Normalize Claude account meters | 4 | DASH-012; `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` |
| [DASH-014](companion-tickets/DASH-014-current-run-summary.md) | Project canonical run summary | 4 | DASH-016 |
| [DASH-021](companion-tickets/DASH-021-financial-data-auth-boundary.md) | Enforce financial-data authentication | 3 | DASH-001 |
| [DASH-022](companion-tickets/DASH-022-current-run-summary-ui.md) | Render accessible current-run summary | 3 | DASH-003, DASH-014 |
| [DASH-015](companion-tickets/DASH-015-usage-provider-summary-ui.md) | Render authenticated provider meters | 3 | DASH-003, DASH-013, DASH-020, DASH-021 |
| [DASH-031](companion-tickets/DASH-031-usage-cost-summary-ui.md) | Render authenticated usage and cost summary | 4 | DASH-003, DASH-010, DASH-013, DASH-020, DASH-021, DASH-025, DASH-029, DASH-030 |
| [DASH-023](companion-tickets/DASH-023-selected-build-order-usage.md) | Integrate selected Build Order usage | 4 | BO-003, BO-012, DASH-030, DASH-031, DASH-021 |
| [DASH-032](companion-tickets/DASH-032-truthful-current-run-recent-outcomes.md) | Project truthful current-run outcomes | 3 | DASH-002, DASH-014 |
| [DASH-034](companion-tickets/DASH-034-current-run-recent-ui.md) | Render current-run Recent outcomes | 3 | DASH-003, DASH-007, DASH-032 |
| [DASH-033](companion-tickets/DASH-033-dashboard-parity-capstone.md) | Prove existing-dashboard parity | 3 | DASH-001, DASH-003, DASH-005, DASH-007, DASH-015, DASH-022, DASH-027, DASH-028, DASH-031, DASH-034 |

Total: 34 tickets, 111 complexity points.

## Why thirty-four

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
  protocol, and review boundaries. Measurement normalization owns the
  provider/source token-relationship contract; provider adapters pin mappings,
  and cost projection consumes them.
- The provider-meter contract precedes Codex and Claude adapters, allowing the
  two provider integrations to proceed in parallel.
- Financial-data authorization must prevent queries/subscriptions/assigns
  before presentation; hiding values in UI is insufficient.
- The nonfinancial Aiur run summary can ship independently from protected
  provider usage and account-meter cards.
- Selected Build Order usage is a cross-source live integration over current
  GitHub membership, not a concern to hide inside the Units-default summary or
  the Build Order feature's own acceptance.
- Row activation opens ticket context while a separate named Chat action opens
  a read-only conversation mirror: the bounded sanitized live-conversation
  projection (DASH-026) and its accessible drawer (DASH-027) are distinct
  trust and interaction boundaries.
- Global runtime capacity presentation over the existing authoritative Slots
  contract (DASH-028) is separate from worker-confirmed per-unit pause/resume
  UI (DASH-005); acceptance of a capacity request is proven only by the
  Orchestrator-returned snapshot.
- The provider-neutral envelope/registry contract (DASH-008) must stay stable
  while installed Codex/Claude headless protocols drift independently, so the
  version-pinned source adapters are their own boundary (DASH-029).
- Exact effective-dated pricing policy (DASH-011) and bounded multidimensional
  grouping/query projection (DASH-030) have different inputs, failure modes,
  and future consumers.
- Provider-meter cards (DASH-015) and the protected usage/cost summary with
  drill-down (DASH-031) degrade independently and serve different consumers.
- Current-run outcome qualification is a server-side evidence join (DASH-032)
  separate from its Units Recent presentation (DASH-034), just as run summary
  and accounting projection/UI are separate.
- The existing-dashboard parity capstone (DASH-033) proves the composed
  experience end to end without joining Build Order acceptance or expanding
  the feature.

The complete evidence matrix is
[06-prototype-capability-audit.md](06-prototype-capability-audit.md).

## Scheduling and shared surfaces

- The shared predecessor baseline is resolved: the bounded predecessor
  dashboard run is complete and `origin/main` at
  `9849f32963c2a65367bce565b3f5ede3777c218f` contains closed #1034 plus every
  accepted OCC successor. Every companion ticket records
  `**Predecessor baseline:** resolved` with that SHA; no shared external gate
  remains before companion dispatch.
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
- DASH-003/005/007/015/021/022/023/027/028/031/034 and BO-012..014 touch
  shared dashboard, authentication, or CSS surfaces and must follow typed
  serialization edges.
  Same-pack edges are symmetric; cross-pack edges are declared by companions
  because the standalone core manifest cannot reference DASH IDs. DASH-001
  serializes with BO-012, and DASH-023 serializes with BO-013/014 while its
  dependency already orders it after BO-012. DASH-023 is hard-ordered after
  DASH-030/031; DASH-022 serializes with DASH-015 and DASH-023 on the shared
  summary layout.
- BO-003/005/016/019 and DASH-002/009/012/018/019/024/025/026 all add
  long-lived children through the current central application supervision
  tree. The
  companion manifest declares every independently ready cross-pack edge and
  every symmetric same-pack edge; existing hard dependencies order the
  remainder. This is a merge/execution mutex, not a data dependency or root
  membership relation.
- DASH-006 and DASH-017 `serialize_with` each other on Decision store/schema
  files. DASH-006 owns read/query behavior; DASH-017 owns durable trusted
  fields and migration.
- DASH-018 solely owns the opaque provider-account generation shared by usage
  and meters. DASH-008/012 consume it, and provider adapters only report
  trusted lifecycle evidence. DASH-018/019 serialize on the shared Claude
  process-lifecycle adapter; DASH-019 still owns only telemetry launch,
  producer authentication, and session correlation.
- DASH-008 owns the versioned provider/source token-dimension relationship
  and provider-total authority; DASH-029 serializes with BO-005's event
  migration and pins the Codex/Claude headless source mappings onto that
  contract. DASH-010 pins Claude base input, cache creation, and cache read
  as additive for each supported telemetry revision. DASH-009 owns raw
  append, counter delta, checkpoint and replay and preserves the pinned
  relationship revision unchanged. DASH-024 owns
  relationship-revision-partitioned aggregate/query recovery; DASH-025 alone
  owns destructive rotation/retention/compaction and preserves every grouping
  and downstream pricing dimension without merging revisions before deletion.
- DASH-011 prices and reconciles additive, subset, and mutually exclusive
  dimensions under the pinned relationship revision, failing closed on unknown
  or contradictory mappings. DASH-030 owns the bounded run/ticket grouped
  query over those exact priced dimensions. DASH-031 alone joins tier facts by
  provider, backend, and exact known generation, with explicit
  unknown/mixed/mismatch states.
- DASH-019 owns secure local Claude transport/correlation and its protocol gate;
  DASH-010 owns only authenticated event-to-envelope mapping. Its BO-004
  prerequisite supplies repository-qualified ticket correlation and does not
  transfer telemetry ownership to the Build Order graph.
- DASH-012 owns the generic meter/LKG contract. DASH-020 and DASH-013 can run in
  parallel after it.
- DASH-021 owns protected query/subscription delivery. DASH-022 receives only
  nonfinancial DASH-014 facts; DASH-015 and DASH-031 receive protected values
  only through DASH-021. Provider/backend/model is protected only inside financial records;
  unauthenticated read-only Units retains nonfinancial StatusReport execution
  backend/model.
- DASH-023 combines BO-003's exact current member generation with DASH-030's
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

| Gate | Human owner | Status | Resolution receipt |
|---|---|---|---|
| `GATE-OCC-PREDECESSOR-BASELINE` | Product owner and current OCC Executor | RESOLVED | Bounded predecessor run is complete; `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f` contains closed #1034 plus all accepted OCC successors |
| `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` | Human owner with `aiur-claude` write authority | Active | Reviewed matrix plus secure Aiur-only path or already-landed pinned compatible sibling revision; otherwise separate sibling issue/PR lands first |
| `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` | Human owner with `aiur-claude` write authority | Active | Reviewed matrix plus existing source or already-landed pinned compatible sibling revision; otherwise separate sibling issue/PR lands first |

Historical note: `GATE-OCC-PREDECESSOR-BASELINE` was an active pre-dispatch
gate on every companion ticket while the bounded predecessor dashboard run was
in flight. It resolved when that run completed and `origin/main` at
`9849f32963c2a65367bce565b3f5ede3777c218f` was confirmed to contain closed
#1034 plus every accepted OCC successor; the resolution was propagated into
the ticket headers during the 2026-07-13 plan reconciliation.

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
`model:codex`. Every issue also records the resolved predecessor baseline in
its contract and carries no dispatch label. Publish the hard prerequisites above as native
blockers, including cross-scope BO edges, but add no Build Order parent,
phase/lane, or active `agent:*` label. Returned identities and full observed
labels live in `dashboard-companions.json`.

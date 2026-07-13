# Standalone Dashboard Companion Tickets

These fifteen tickets implement the capability delta between current OCC main
and the refreshed prototype. They are intentionally not members, completion
requirements or ETA inputs of the Build Order root.

| ID | Outcome | Cx | Hard prerequisites |
|---|---|---:|---|
| [DASH-001](companion-tickets/DASH-001-responsive-route-shell.md) | Responsive route-aware shell | 3 | BO-008 |
| [DASH-002](companion-tickets/DASH-002-current-run-units-catalog.md) | Canonical current-run Units catalog | 4 | BO-005 |
| [DASH-003](companion-tickets/DASH-003-units-interface.md) | Responsive Units filters/table | 3 | DASH-001, DASH-002, BO-011 |
| [DASH-004](companion-tickets/DASH-004-applied-unit-control-protocol.md) | Worker-applied pause/resume protocol | 4 | — |
| [DASH-005](companion-tickets/DASH-005-unit-capacity-controls-ui.md) | Unit and positive-capacity controls | 3 | DASH-002, DASH-003, DASH-004 |
| [DASH-006](companion-tickets/DASH-006-decision-lookup-provenance.md) | Decision lookup/provenance contract | 4 | — |
| [DASH-007](companion-tickets/DASH-007-commands-interface.md) | Commands presentation catch-up | 3 | DASH-001, DASH-006 |
| [DASH-008](companion-tickets/DASH-008-usage-envelope.md) | Provider-neutral usage envelope | 4 | BO-004 |
| [DASH-009](companion-tickets/DASH-009-durable-usage-ledger.md) | Durable attributed usage ledger | 4 | DASH-008 |
| [DASH-010](companion-tickets/DASH-010-claude-remote-usage.md) | Required Claude Remote accounting | 4 | DASH-008; `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` |
| [DASH-011](companion-tickets/DASH-011-cost-grouping-projection.md) | Versioned cost/grouping projection | 4 | DASH-009 |
| [DASH-012](companion-tickets/DASH-012-codex-provider-meters.md) | Meter contract and Codex adapter | 4 | DASH-008 |
| [DASH-013](companion-tickets/DASH-013-claude-provider-meters.md) | Claude subscription/API meter parity | 4 | DASH-012; `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` |
| [DASH-014](companion-tickets/DASH-014-current-run-summary.md) | Canonical current-run summary | 4 | DASH-002 |
| [DASH-015](companion-tickets/DASH-015-usage-run-summary-ui.md) | Authenticated usage/run summary UI | 4 | DASH-001, DASH-003, DASH-010..014 |

Total: 15 tickets, 56 complexity points.

## Why fifteen

- Units membership/predicate truth is separate from presentation and from the
  applied mutation boundary.
- Runtime control request acceptance is not worker application; the protocol
  must exist before the toggle UI can claim success.
- Decision durable lookup/provenance is separate from Commands vocabulary and
  card composition.
- Measurement normalization, durability, Remote Control ingestion and pricing
  have different correctness/storage/protocol boundaries.
- Account quotas are not ticket accounting; Codex and Claude use different
  provider contracts.
- Live/remaining/progress/elapsed/ETA needs one canonical projection before the
  summary UI can render truthful values.

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
- DASH-002 and DASH-008 consume BO typed activity/identity contracts; DASH-008
  serializes with BO-005's event migration.
- DASH-008 solely owns the privacy-safe opaque provider-account-generation
  namespace shared by usage and meter snapshots. DASH-012 consumes it; neither
  adapter may conflate it with a resettable counter/provider epoch.
- DASH-003 consumes BO-011 ticket context rather than building a second modal.
- DASH-003/005/007/015 and BO-012..014 touch shared dashboard composition/CSS
  and must be sequenced or rebased.
- DASH-006 and runtime identity producers coordinate schema provenance; exact
  backend/model values are never parsed from display text.
- DASH-009 preserves occurrence-price date, currency, provider-account
  generation, and every downstream grouping dimension through compaction.
  DASH-011 exposes generation-qualified groups but does not join meter data;
  DASH-015 alone joins tier facts by provider, backend, and exact known
  generation, with explicit unknown/mixed states.
- DASH-010/013 are not dispatchable until their named human-owned protocol gate
  has a resolution receipt. Their Aiur issues remain incomplete while a required
  external contract is blocked.

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
- #1033 documents the current dashboard; these companions own documentation
  for their future behavior.

## Publication

Create these as standalone issues with one `complexity:N` and `model:codex`.
Publish the hard prerequisites above as native blockers, including cross-scope
BO edges, but add no Build Order parent, phase/lane or active `agent:*` label.
Returned identities and full observed labels live in
`dashboard-companions.json`.

# Companion History

These thirty-four DASH tickets were originally planned as a standalone
dashboard track alongside the Build Order pack. On 2026-07-13 the operator
decided to consolidate the program into a single Build Order: every DASH
ticket is now a direct member of the one GitHub root, and
[`build-order.json`](build-order.json) is the authoritative index for all 54
members, their lanes, phases, dependencies, and serialization edges. The
separate companion manifest (`dashboard-companions.json`) was retired with
that decision; separation now lives in the `build-lane:*` epics and
`phase:*` hints, not in membership.

The two Claude-protocol gates the companions carried travelled with them:
`GATE-003` (Claude telemetry protocol authority, DASH-019) and `GATE-004`
(Claude meter protocol authority, DASH-013) are registered in
`build-order.json`'s external-gate registry. The historical
`GATE-OCC-PREDECESSOR-BASELINE` resolved before consolidation — the bounded
predecessor dashboard run completed and `origin/main` at
`9849f32963c2a65367bce565b3f5ede3777c218f` contains closed #1034 plus every
accepted OCC successor — and is referenced by no ticket.

## Ownership boundaries (still authoritative)

The ownership split between these tickets remains useful and unchanged by
consolidation:

- Recoverable current-run membership (DASH-002) is a durable state owner;
  rich Units rows, predicates, counts, and URL policy (DASH-016) are a
  separate pure read-model contract.
- Runtime control request acceptance (DASH-004) is not worker application;
  the protocol must exist before toggle UI (DASH-005) can claim success.
- Retained Decision lookup/query behavior (DASH-006) is independent from
  trusted durable provenance schema and migration (DASH-017). Both serialize
  on shared store surfaces without a false semantic dependency, while
  existing integer `0..100` supervisor confidence remains unchanged.
- Privacy-safe provider-account identity (DASH-018) is shared
  infrastructure, not usage- or meter-local state.
- Measurement normalization (DASH-008), raw append/delta/replay (DASH-009),
  aggregate/query recovery (DASH-024), destructive retention/compaction
  (DASH-025), authenticated Claude telemetry transport (DASH-019), Remote
  event mapping (DASH-010), and cost projection (DASH-011) have distinct
  trust, storage, protocol, and review boundaries. Measurement normalization
  owns the provider/source token-relationship contract; provider adapters
  pin mappings, and cost projection consumes them.
- The provider-meter contract (DASH-012) precedes the Codex (DASH-020) and
  Claude (DASH-013) adapters, allowing the two provider integrations to
  proceed in parallel.
- Financial-data authorization (DASH-021) must prevent
  queries/subscriptions/assigns before presentation; hiding values in UI is
  insufficient.
- The nonfinancial Aiur run summary (DASH-014/022) can ship independently
  from protected provider usage and account-meter cards (DASH-015/031).
- Selected Build Order usage (DASH-023) is a cross-source live integration
  over current GitHub membership, not a concern to hide inside the
  Units-default summary.
- Row activation opens ticket context while a separate named Chat action
  opens a read-only conversation mirror: the bounded sanitized
  live-conversation projection (DASH-026) and its accessible drawer
  (DASH-027) are distinct trust and interaction boundaries.
- Global runtime capacity presentation over the existing authoritative Slots
  contract (DASH-028) is separate from worker-confirmed per-unit
  pause/resume UI (DASH-005); acceptance of a capacity request is proven
  only by the Orchestrator-returned snapshot.
- The provider-neutral envelope/registry contract (DASH-008) must stay
  stable while installed Codex/Claude headless protocols drift
  independently, so the version-pinned source adapters are their own
  boundary (DASH-029).
- Exact effective-dated pricing policy (DASH-011) and bounded
  multidimensional grouping/query projection (DASH-030) have different
  inputs, failure modes, and future consumers.
- Provider-meter cards (DASH-015) and the protected usage/cost summary with
  drill-down (DASH-031) degrade independently and serve different consumers.
- Current-run outcome qualification is a server-side evidence join
  (DASH-032) separate from its Units Recent presentation (DASH-034), just as
  run summary and accounting projection/UI are separate.
- The existing-dashboard parity proof (DASH-033) stays an executable member
  inside the graph; BO-015 remains the single program capstone and now
  hard-depends on it.

The complete evidence matrix is
[06-prototype-capability-audit.md](06-prototype-capability-audit.md).

## Existing-work disposition

- DASH-009/024/025 supersede #132's storage/accounting contract. The
  proposed opencode TUI surface stays separate and is recorded in the
  deferred ledger.
- DASH-009/024/025/011 relate to #845, but this bounded local-first program
  does not pull in its Postgres/multi-controller/BI scope.
- Debug-only #930 is evidence, not normal-run accounting truth.
- Closed #1033 documents the current dashboard; these tickets own
  documentation for their future behavior.

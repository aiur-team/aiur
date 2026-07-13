# BO-001 — Define Build Order domain contract

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — One strict, pure domain and validation boundary

**Risk:** high

**Phase hint:** 1

**Depends on:** none

**Serializes with:** none

**External gates:** GATE-001 (integration baseline), GATE-002 (Executor skill)

**Requirements:** BOREQ-001, BOREQ-002, BOREQ-003

**Decisions:** DEC-001, DEC-002, DEC-003, DEC-004, DEC-010, DEC-013

**Design evidence:** DESIGN-002

**Researched at:** 1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d

**Suggested labels:** `complexity:3`, `model:codex`, `phase:1`, `build-lane:backend`; never `agent:todo`

## Outcome

Aiur has one strict, pure Build Order contract that represents root catalogs,
selected graphs, members, native dependencies, planning metadata, provider
health, structural validity, edge satisfaction, and ticket readiness without
performing I/O or consulting runtime processes.

## Context and evidence

The dispatch-oriented `Aiur.Issue` shape does not retain every GitHub identity,
parent, state-reason, catalog, graph-health, or diagnostic fact needed here.
Existing complexity parsing also tolerates duplicate labels by choosing a
value; a planning view must expose ambiguity instead. If provider, presenter,
and browser work invent separate meanings for invalid, blocked, or complete,
the resulting graph can look ready while its source data is incomplete.

This ticket is the contract gate for every other Build Order implementation
ticket. It defines semantics and bounded fixtures, not transport or UI.

It must not be dispatched until the user records both external gates as
resolved on the live root: the configured integration target contains the
completed Operator Control Center baseline used by this plan, and the bounded
Executor skill revision from PR #1065 commit `0daf2972` (or an explicitly
reviewed compatible successor) is installed and discoverable.

## Scope

- Define root-summary, selected-root, member, repository-qualified identity,
  native dependency reference, provider generation/health, metadata warning,
  lifecycle outcome, edge state, readiness, and structural-diagnostic records.
- Parse exactly one `complexity:1..5`, one positive `phase:N`, and one controlled
  `build-lane:*`. Missing or duplicate values remain renderable as explicit
  unknown/unphased/unassigned warnings.
- Define edge states exactly as `cleared`, `blocking`,
  `terminal_unsatisfied`, `unknown`, and `cyclic`.
- Define member readiness precedence as `cyclic > unknown >
  terminal_unsatisfied > blocking > ready`; phase and Aiur progress never
  override that precedence.
- Treat only `CLOSED + COMPLETED` as a cleared blocker. Open blockers are
  blocking; `NOT_PLANNED` is terminal-unsatisfied; missing, stale, or
  incomplete facts are unknown; self-loops and strongly connected components
  are cyclic.
- Distinguish catalog-entry validity, selected-root structural invalidity,
  provider stale/unavailable state, and member metadata warnings. One malformed
  root cannot invalidate or hide otherwise valid catalog entries.
- Parse the bounded hidden root/ticket logical-identity markers, safe GitHub
  URLs, state reasons, and representative bounded fixtures without raising on
  untrusted strings.

## Non-goals

- Fetch GitHub, supervise a cache, fold Aiur events, join runtime activity, or
  render cards and edges.
- Support Linear, cross-repository membership, nested members, more than 100
  direct members, or GitHub planning mutations.
- Treat a malformed optional marker or planning label as permission to discard
  an otherwise identifiable member.

## Existing owner and reuse target

Reuse GitHub identity/state/label vocabulary around `Aiur.Issue`,
`Aiur.GitHub.IssueState`, and `Aiur.GitHub.Labels`, while keeping Build Order
records in a bounded namespace. Reuse existing structured-error conventions.
Do not add graph/catalog/presentation fields to the general dispatch record;
BO-004 separately owns the cross-consumer typed tracker identity needed by
StatusReport and event joins.

## Contract and invariants

- Canonical joins and caches use tracker kind, repository identity, and GitHub
  node identity; issue number remains a mutable locator and display value.
- Root-catalog validity is per entry. Selecting an invalid root yields an
  explicit structural-invalid result, not an empty catalog or provider error.
- Member metadata ambiguity produces diagnostics and fallbacks while the member
  remains visible. Structural identity/membership failure is classified
  separately.
- Planned phase, edge state, readiness, GitHub outcome, Aiur execution state,
  agent stage, and progress are distinct fields.
- Every parser is total over bounded input. Unknown data never becomes empty,
  zero, cleared, or ready.

## Refreshable implementation notes

- Place small pure modules under the current Build Order bounded context after
  refreshing naming and module-size constraints on the configured integration
  branch.
- Use explicit tables and property checks rather than parsing the prototype's
  illustrative JavaScript data.
- Keep the public vocabulary stable; downstream tickets may refine internal
  storage but must not silently rename these outcomes.

## Acceptance and verification

### Agent gate

- Pure tests cover every edge state and precedence combination, all GitHub
  state reasons, self-loops/SCCs, external references, stale and missing facts,
  and Aiur `100%` progress on an open blocker.
- Parser tests cover missing, duplicate, malformed, and valid planning labels;
  optional markers; unsafe URLs; root-with-parent; 0/1/100/101 members; and
  bounded arbitrary strings without exceptions.
- Catalog tests prove one malformed root does not hide valid siblings, selected
  structural-invalid differs from stale/unavailable, and member warnings do not
  erase the member.

### At-merge gate

- Compile, formatting, specs/lint, focused tests, and the repository CI gate
  pass on the current configured integration branch.
- Public record and enum names are reconciled with every dependent ticket
  before concurrent work begins.

### Human/manual evidence

- None separately; BO-015 owns integrated Executor evidence.

## Failure, security, migration, and accessibility cases

- Bound labels, markers, titles, descriptions, and URLs before parsing or
  rendering; never preserve credentials or raw provider errors.
- This introduces no persisted-state migration. Any later stored snapshot must
  version this contract explicitly.
- Diagnostics must have concise accessible text; visual color or icon is never
  the only expression of an edge/readiness state.

## Surfaces

- Reads: current issue, GitHub identity, label, and state-reason contracts;
  captured feature constraints.
- Writes: pure Build Order records, parsers, validation policies, and fixtures.
- Contracts: catalog/selected-root validity; member metadata; edge-state and
  readiness vocabulary; repository-qualified identity.

## Sibling boundaries and open gates

BO-002 owns transport normalization, BO-003 owns supervised generations,
BO-007 owns the joined view model, and BO-012 owns routes. No companion ticket
may redefine this domain contract; it may only reuse its identities or schedule
around the same modules. GATE-001 and GATE-002 are
pre-dispatch gates, not feature tickets or additions to the completion
denominator.

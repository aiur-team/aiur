# BO-001 — Define Build Order domain contract

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — One strict, pure domain and validation boundary

**Risk:** high

**Phase hint:** 1

**Depends on:** BO-004

**Serializes with:** none

**Requirements:** BOREQ-001, BOREQ-002, BOREQ-003

**Decisions:** DEC-001, DEC-002, DEC-003, DEC-004, DEC-010, DEC-013

**Design evidence:** DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-sol`, `phase:1`, `build-lane:plan-graph`; never `agent:todo`

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

This ticket is the contract gate for Build Order graph providers, presentation,
layout, and routes. It imports BO-004's configured-repository identity as the
only member/endpoint identity instead of defining a Build Order copy. The
browser harness (BO-008) remains the other initial independent node; generic
detail/history/context work has its own contracts. This ticket defines graph
semantics and bounded domain fixtures, not transport or UI.

Its GATE-001/GATE-002 readiness is inherited transitively from BO-004. Do not
duplicate gate state on this issue or dispatch it before BO-004 is complete.

## Scope

- Define root-summary, selected-root, member, repository-qualified identity,
  native dependency reference, provider generation/health, metadata warning,
  lifecycle outcome, edge state, readiness, and structural-diagnostic records.
- Import BO-004's configured-repository identity unchanged for roots, members,
  and same-repository endpoints. Preserve other-repository endpoints only as
  nonfetchable external diagnostics with a separately validated outbound URL.
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
- Define Aiur-owned derived lane-icon and status-icon keys plus an accessible
  generic fallback. GitHub labels/state feed the derivation; GitHub provides no
  icon metadata and prototype icon values are never provider truth.
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

Reuse BO-004 identity and GitHub state/label vocabulary around `Aiur.Issue`,
`Aiur.GitHub.IssueState`, and `Aiur.GitHub.Labels`, while keeping Build Order
records in a bounded namespace. Reuse existing structured-error conventions.
Do not add graph/catalog/presentation fields to the general dispatch record or
redefine BO-004's identity.

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
- Lane/status icon keys are deterministic derived presentation hints with
  accessible text and a generic fallback; they are not GitHub metadata.
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
- Identity/icon tests prove BO-004 identity is reused exactly, other-repository
  endpoints remain nonfetchable diagnostics, every normalized lane/status maps
  deterministically, and unknown input uses generic accessible fallbacks.

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

- Reads: BO-004 configured-repository identity; current issue label and
  state-reason contracts; captured feature constraints.
- Writes: pure Build Order records, parsers, validation policies, and fixtures.
- Contracts: catalog/selected-root validity; member metadata; edge-state and
  readiness vocabulary; imported configured-repository identity; derived
  lane/status icon keys and generic fallback.

## Sibling boundaries and open gates

BO-002 owns graph transport normalization, BO-003 owns supervised graph
generations, BO-007 owns the joined view model, and BO-012 owns routes. BO-004
owns identity; BO-008 owns the browser harness; BO-016/019/018 own generic
detail, history, and base context without Build Order relationship assumptions.
No companion ticket may redefine this domain contract; it may only reuse its
identities or schedule around the same modules. GATE-001 and GATE-002 are
inherited through BO-004, not duplicated on BO-001 or added to the completion
denominator.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-001`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

# BO: BO-002 — Fetch complete GitHub planning graph

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Bounded multi-connection GitHub adapter with partial-failure semantics

**Risk:** high

**Phase hint:** 2

**Depends on:** BO-001

**Serializes with:** none

**Requirements:** BOREQ-001, BOREQ-002, BOREQ-003, BOREQ-004

**Decisions:** DEC-001, DEC-002, DEC-003, DEC-004, DEC-005

**Design evidence:** DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex-gpt-5.6-terra`, `phase:2`, `build-lane:plan-graph`; never `agent:todo`

## Outcome

Aiur can fetch a bounded root catalog and one complete body-free selected Build
Order candidate from GitHub, preserving native identity, membership, labels,
lifecycle outcomes, dependency endpoints, pagination, and partial failures
without publishing incomplete data as valid.

## Context and evidence

GitHub exposes `Issue.parent`, `subIssues`, `blockedBy`, and `blocking`, while
Aiur's landed ordinary GitHub issue path does not currently hydrate a complete,
provider-health-aware dependency graph. The in-flight PR #1012 path is designed
for dispatch-oriented per-issue `blocked_by` hydration and may collapse a
dependency-fetch failure to an empty list. Neither is safe as the planning-view
contract: losing page two or one endpoint must not make a dependent appear
ready. Browser-count-dependent or per-node polling would also exhaust provider
budgets at the 100-member bound.

## Scope

- Add transport operations for a paginated root catalog and a selected root's
  direct members, identity/database IDs, bounded card title/metadata, labels,
  state and state reason, parent, timestamps, and native dependency
  connections. Root/member graph payloads remain body-free.
- Add validated provider configuration for catalog root bound (default `100`),
  finite page budget, and finite per-refresh provider-call budget. Page/call
  budgets have positive defaults selected against the current schema, a hard
  implementation ceiling, and cannot be disabled with zero/infinity.
- Use bounded GraphQL reads where they preserve complete connection/error
  semantics; use paginated REST fallbacks only through the existing transport
  and with equivalent failure preservation.
- Normalize every response into BO-001 candidate records while retaining
  repository-qualified endpoint identities, external dependency references,
  connection counts, provider request metadata, and rate-limit observations.
- Fetch roots/members only from the configured repository. Preserve a
  dependency endpoint naming another repository as a nonfetchable external
  diagnostic plus an optional separately validated GitHub URL; never follow it
  with provider I/O or treat it as an internal missing member.
- Reject a candidate on any required page/field error, pagination/count
  mismatch, duplicate canonical identity, contradictory internal endpoint
  locator, over-limit membership, or structurally invalid selected root.
  After complete member pagination, retain a valid same-repository dependency
  endpoint absent from the selected member set as an unknown edge rather than
  treating it as missing provider data.
- Detect exact configured bounds without truncation. A root catalog at 100 and
  a selected graph at 100 members succeed by default; `bound + 1`, `hasNextPage`
  at the bound, exhausted page budget, or exhausted call budget is a structured
  preserving overflow/failure for BO-003, never a partial successful catalog or
  graph.
- Return catalog entries independently: a malformed root carries its diagnostic
  while valid roots remain selectable. Catalog-level auth/transport failure is
  separate from per-root structural invalidity.
- Keep member metadata warnings renderable. Missing/duplicate phase, lane,
  complexity, or optional marker does not turn a complete provider generation
  into an empty graph.
- Bound calls and payloads independently of member count and connected browser
  count; classify auth, permission, rate-limit, timeout, network, GraphQL
  partial, schema, and validation failures.

## Non-goals

- Supervise refresh cadence, retain last-known-good graph generations,
  broadcast PubSub updates, join Aiur activity, fetch selected-ticket detail,
  or render UI.
- Mutate sub-issues, labels, issue state, or dependencies.
- Reuse a per-member N+1 hydration path or silently treat a failed connection
  as `[]`.

## Existing owner and reuse target

Extend `Aiur.GitHub.Transport`, the existing issue-state/label normalization,
and native sub-issue/dependency API knowledge. Keep this adapter separate from
ordinary tracker polling and `Aiur.GitHub.IssueDependencies` mutation logic.

## Contract and invariants

- Success means the entire requested catalog page set or selected-root
  generation is complete and bounded. Partial success is an error with
  evidence, never a smaller successful result.
- Dependency direction normalizes to blocker → blocked while preserving both
  upstream and downstream source connections for reconciliation.
- Internal identities resolve by repository plus node ID. A number, title, or
  logical marker is never sufficient to join endpoints.
- Structural-invalid selected roots, malformed catalog entries, stale cache,
  and provider unavailable are distinct results for BO-003.
- The adapter performs no retry loop, cache swap, or browser-specific work.

## Refreshable implementation notes

- Re-introspect the authenticated GitHub schema and current REST API version at
  pickup; protocol fields are evidence, not timeless assumptions.
- Add new Build Order adapter modules beside the existing transport rather than
  expanding an already-large ordinary issue poller.
- Record query cost/call bounds in fixtures and expose enough response metadata
  for BO-003 health and retry policy.

## Acceptance and verification

### Agent gate

- Fixtures cover 0/1/100 members, multiple catalog roots, malformed root among
  valid siblings, direct-child enforcement, duplicate identities, external
  blockers, `COMPLETED`/`NOT_PLANNED`, every planning-label warning, and cycles.
- Cross-repository fixtures prove no follow-up I/O, no internal join, explicit
  diagnostic state, and optional safe outbound-link validation.
- Pagination tests fail closed on page two errors, count drift, partial GraphQL
  data, malformed cursors, missing endpoints, and 101 members.
- Call-bound tests prove no browser-count or per-node N+1 behavior and retain
  rate-limit/auth/timeout classification without secrets.
- Configuration tests cover the default 100 roots, lower valid bounds, invalid
  zero/unbounded values, exact-bound success, `+1` overflow, page exhaustion,
  call-budget exhaustion, and preservation of the prior BO-003 generation.

### At-merge gate

- Current GitHub schema fixtures, transport tests, compile/lint/spec checks,
  and full repository CI pass on the current configured integration branch.
- No regression weakens existing dependency mutation or ordinary tracker
  polling behavior.

### Human/manual evidence

- None separately; BO-015 exercises the published root through the real
  provider path.

## Failure, security, migration, and accessibility cases

- Use configured GitHub auth and trusted repository/host policy; never log
  tokens, raw authorization headers, private bodies, or unredacted responses.
- No persisted migration; normalized candidate contracts are versioned through
  BO-001.
- Provider errors must carry safe Executor text suitable for later accessible
  status rendering.

## Surfaces

- Reads: GitHub GraphQL/REST through the existing transport; BO-001 contracts.
- Writes: GitHub Build Order read adapter, normalization fixtures, and tests.
- Contracts: complete root-catalog candidate; complete body-free selected-root
  candidate; configurable hard root/page/call bounds; provider failure taxonomy.

## Sibling boundaries and open gates

BO-003 alone owns refresh/cache/LKG behavior for catalog and graph. BO-016 owns
root-independent on-demand ticket detail and its cache; BO-011/012 consume
their respective established contracts, not this adapter directly. Companion
dashboard work neither blocks nor extends this provider and may only serialize
if it changes the shared GitHub transport.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-002`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

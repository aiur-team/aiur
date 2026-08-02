# BO: DASH-030 — Project grouped usage scopes

**Kind:** executable

**Provenance:** planned in plan v1 after the shipped-dashboard capability re-audit

**Complexity:** 3 — Bounded multidimensional grouping over established aggregate and pricing contracts

**Risk:** high

**Phase hint:** 6

**Depends on:** DASH-011, DASH-024

**Serializes with:** none

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-030

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:6`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Aiur exposes bounded, exact, scope-labelled token and estimate summaries for a
caller-supplied run and/or repository-qualified ticket set, with reconciled
provider, ticket, agent-family, backend, model, currency, account-generation,
pricing, relationship, and retained-coverage contributors.

## Context and evidence

DASH-011 originally combined immutable effective-dated pricing with every
grouping/query scope required by the prototype. Pricing policy and query
projection have different inputs, failure modes, and future consumers. This
ticket consumes DASH-024's crash-safe aggregates and DASH-011's exact priced
dimensions; it never discovers a Build Order or joins a current provider tier.

## Scope

- Define a bounded query accepting explicit typed run identities and/or exact
  configured-repository ticket identities. A request declares `this_run`,
  `explicit_ticket_set`, or their supported intersection; bare issue numbers,
  visible rows, and labels are never scope authority.
- Return canonical tokens plus separately labelled
  `provider_reported_estimate`, `api_equivalent_estimate`, and unknown monetary
  coverage by provider, ticket, agent family, backend, exact resolved model,
  auth mode, currency, opaque provider-account generation, run, occurrence-
  price partition/revision, and token-relationship revision.
- Preserve contributor buckets and produce one exact compatible-currency API-
  equivalent roll-up across providers/account generations for each requested
  scope. Reconcile every roll-up to provider, generation, ticket, agent,
  backend, and model constituents without combining unlike bases or currencies.
- Include pricing/model/token/relationship/attribution coverage, unknown
  contributors, store health, aggregate generation, earliest/latest retained
  coverage, and deterministic partial/known-empty/unavailable states.
- Include all retained observations for an explicit current-member ticket set,
  including pre-membership usage, while excluding nonmembers. Membership is
  supplied by DASH-023 and is never stored or inferred here.
- Emit a generation-qualified tier-join key of `(provider, backend,
  provider_account_generation)` only for exact known contributor groups.
  Unknown/mixed groups have no synthetic key; this ticket never reads meters.
- Support bounded pagination/drill-down summaries without scanning raw ledger
  segments or materializing unbounded browser data. Publish immutable snapshots
  and changes suitable for DASH-021's protected facade.
- Keep run/build scopes, compatible-currency totals, and contributor totals
  exactly reproducible across restart, replay, and retained compaction.

## Non-goals

- Define price tables or token arithmetic, ingest/persist/compact usage, fetch
  provider meters, join plan tiers, render UI, or discover Build Order roots.
- Allocate subscription fees, call organization billing APIs, merge currencies
  or monetary bases, infer ticket identity, or treat missing coverage as zero.
- Write usage or membership back to GitHub.

## Existing owner and reuse target

Build a pure grouped query layer over DASH-024 snapshots and DASH-011's exact
pricing/reconciliation results. Keep it provider-neutral and callable by both
the Units `this run` view and DASH-023's explicit selected-build adapter.

## Contract and invariants

- Scope is an explicit typed input. The projection cannot discover, retain, or
  mutate Build Order membership and never equates rendered rows with a build.
- Every value preserves scope, basis, currency, generation, pricing/relationship
  revisions, attribution coverage, retained interval, and provider health.
- Group and roll-up arithmetic is exact and reconciles in both directions.
  Unlike bases/currencies never combine; unknown contributors remain visible.
- Tier keys exist only for exact known provider/backend/account generations and
  carry no account identity. Meter data cannot enter this projection.
- A healthy empty query, missing retained interval, partial/corrupt source,
  stale snapshot, and unavailable projection remain distinct.

## Refreshable implementation notes

- Refresh DASH-024/DASH-011 schemas at pickup and keep adapters at their public
  boundaries rather than reading storage files or price tables directly.
- Use deterministic canonical ordering and exact-decimal/integer arithmetic.
  Bound every group, cursor, page, and serialized snapshot.
- Include scope and every authority generation in cache keys; reject stale
  asynchronous results instead of relabelling them.

## Acceptance and verification

### Agent gate

- Property tests cover run-only, explicit-ticket, intersection, empty, partial,
  pre-membership, removed/nonmember, typed repository collision, mixed account
  generations, currencies, bases, revisions, models, and coverage.
- Reconciliation tests prove all compatible-currency roll-ups equal their
  preserved contributors, provider-reported values remain separate, and
  unknown/contradictory pricing or relationships cannot become zero.
- Restart/retention tests prove equivalent results before/after replay and
  compaction, bounded pagination, stale-generation rejection, and no raw-ledger
  or provider-meter access.

### At-merge gate

- Rebase on DASH-011/024 and run aggregate, pricing, exact-money, scope,
  retention, security, property, and full CI suites.

### Human/manual evidence

- Review a synthetic mixed Codex/Claude run and explicit build set. Show one
  compatible-currency API-equivalent total reconciling to every visible
  provider/ticket/model/agent contributor while unlike bases/currencies and
  missing coverage remain separate.

## Failure, security, migration, and accessibility cases

- One degraded partition yields explicit partial coverage without erasing
  healthy groups or inventing a zero total.
- Treat grouped usage as protected Executor data. Never log query rows, raw
  account identity, prompts, outputs, credentials, or provider payloads.
- Version query/snapshot and cache-key schemas; retained revisions and coverage
  survive migration. Human-readable reason keys support downstream accessible
  presentation.

## Surfaces

- Reads: DASH-024 aggregate/query snapshots and DASH-011 exact priced/token
  reconciliation; caller-supplied typed scopes.
- Writes: grouped usage query/projection, bounded cursors/snapshots, change
  notifications, fixtures, and tests.
- Contracts: exact run/ticket scopes, contributor reconciliation, compatible-
  currency roll-ups, and exact-generation tier keys.
- Safety: protected grouped data and stale-generation isolation.

## Sibling boundaries and open gates

DASH-011 owns price and token-dimension policy. DASH-031 owns authenticated
presentation and exact-generation meter composition. DASH-023 alone translates
selected GitHub membership into an explicit ticket set.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-030`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

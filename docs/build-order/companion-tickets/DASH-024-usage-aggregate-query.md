# BO: DASH-024 — Project durable usage aggregates

**Kind:** executable

**Provenance:** planned in plan v1 after storage-program split

**Complexity:** 4 — Crash-safe multidimensional aggregate/checkpoint recovery and bounded query behavior

**Risk:** high

**Phase hint:** 5

**Depends on:** DASH-009

**Serializes with:** BO-003, BO-005, BO-016, BO-019, DASH-002, DASH-012, DASH-019, DASH-026 — application supervision tree; the raw-ledger and compaction owners are hard-ordered

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-024

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex-gpt-5.6-terra`, `phase:5`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Aiur maintains crash-safe exact usage aggregates and bounded queries over DASH-009 deltas, preserving every downstream attribution/pricing dimension with explicit health, freshness, generation, and coverage.

## Context and evidence

DASH-009 supplies one replayable raw/delta authority. Dashboard and pricing consumers need bounded snapshots rather than scanning raw segments per browser or query. Rotation/retention remains DASH-025 so aggregate correctness can land and be reviewed before destructive compaction is authorized.

## Scope

- Consume only DASH-009 ordered accepted deltas/replay positions; never become a second raw envelope, idempotency, or counter owner.
- Maintain exact aggregate partitions by provider, run, typed ticket, attempt,
  opaque account generation including unknown, backend, agent family, exact
  resolved model, auth mode, UTC pricing-effective date, token dimension,
  `token_relationship_revision` including unknown, monetary basis, and
  currency.
- Write aggregate/checkpoint snapshots via same-filesystem temporary file, flush, atomic rename, schema/version/checksum, and a source ledger position/generation.
- Recover by validating the latest aggregate checkpoint and replaying DASH-009 deltas after its source position. Missing/corrupt aggregate state rebuilds from the retained DASH-009 raw authority.
- Expose exact bounded snapshot/query primitives by explicit typed run/ticket sets, aggregate generation, health/freshness, raw/projected coverage bounds, and PubSub changes.
- Preserve group-to-total reconciliation and explicit unknown attribution/coverage. Empty, partial, stale, corrupt, and unavailable states remain distinct.
- Supply a stable aggregate/query behavior to DASH-011 and DASH-025; neither consumer reads implementation files directly.
- Document #132 storage/accounting coverage and the future #845 backend seam without mutating those issues.

## Non-goals

- Append raw envelopes, derive/deduplicate deltas, rotate/delete/compact raw segments, apply retention, calculate price estimates, join meter tiers, or render UI.
- Scan raw files per browser, introduce a database, or merge away any listed grouping dimension.
- Claim retention beyond current DASH-009 raw coverage before DASH-025 lands.

## Existing owner and reuse target

Add a supervised projection/query implementation beside DASH-009's behavior, using existing atomic/checksummed snapshot, replay position, exact-decimal, PubSub, and health patterns.

## Contract and invariants

- DASH-009 owns source truth; aggregate state is reproducible from retained ordered deltas.
- Every downstream grouping/pricing dimension survives projection unchanged.
  Known/unknown token-relationship revisions, account generations, dates,
  currencies, bases, models, and identities never merge.
- Snapshot source position and checksum make crash/replay idempotent; duplicate projection delivery cannot inflate totals.
- Queries accept repository-qualified typed ticket/run sets and never key by bare issue number.
- Group sums reconcile exactly to their matching scope/basis/currency/generation total with explicit coverage gaps.

## Refreshable implementation notes

- Refresh DASH-009's final replay/position behavior at pickup and consume it through the public seam only.
- Use exact integer/decimal arithmetic and property fixtures spanning every dimension.
- Keep projection state, checkpoint codec, replay, query policy, and PubSub modules bounded and independently tested.
- Reconcile the central application supervision tree with every declared
  serialization peer before either overlapping branch executes or merges.

## Acceptance and verification

### Agent gate

- Property fixtures vary provider, run, ticket, attempt, backend, agent family,
  exact model, auth mode, account generation, UTC date, token dimension,
  token-relationship revision including unknown, basis, and currency and prove
  exact partition/reconciliation. Identical dimensions under two relationship
  revisions remain separate groups.
- Crash/recovery tests stop before/after aggregate update/checkpoint/publish and
  prove deterministic rebuild from DASH-009 without duplicate totals or
  revision substitution/merging.
- Query tests cover explicit run/ticket sets, typed identity collision, empty/partial/unknown, stale/corrupt/unavailable health, bounded reads, and browser-count-independent work.
- Failure injection covers snapshot write/flush/rename/checksum/schema/source-position mismatches and safe LKG behavior.

### At-merge gate

- Rebase on DASH-009 and the resolved configured integration target; run ledger replay, aggregate/checkpoint/query, exact arithmetic, PubSub, state-directory, security, and full CI suites.

### Human/manual evidence

- Replay synthetic multi-dimensional usage through a projection restart and show identical totals/groups/coverage without scanning files from the browser.

## Failure, security, migration, and accessibility cases

- Projection corruption/failure preserves validated LKG with visible coverage/health and never resets totals or edits DASH-009 source truth.
- Aggregates remain content-free and owner-only; never log rows, account PII, credentials, prompts, or raw provider data.
- Version aggregate/checkpoint/query behavior. Rebuild from DASH-009 is the migration path while retained source permits it.
- No direct UI; query health/coverage/reasons are stable human-readable values.

## Surfaces

- Reads: DASH-009 ordered delta/replay behavior with pinned token-relationship
  revisions and source coverage.
- Writes: relationship-revision-partitioned aggregate/checkpoint snapshots,
  bounded query projection, health/freshness/generation PubSub.
- Contracts: exact multidimensional usage aggregate/query behavior that never
  merges token-relationship revisions.
- Safety: reproducible projection, exact reconciliation, no raw-store mutation,
  and the application supervision tree.

## Sibling boundaries and open gates

DASH-011 applies pricing/grouping policy through this query seam. DASH-025
hardens retained coverage and compaction without changing query semantics.
Declared serialization peers share only the central application supervision
tree. DASH-015 waits for DASH-025 before presenting retained totals as
production-ready.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-024`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

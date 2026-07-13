# DASH-025 — Harden usage retention and compaction

**Kind:** executable

**Provenance:** planned in plan v1 after storage-program split

**Complexity:** 4 — Destructive rotation/retention protocol with dimension-preserving compaction and crash recovery

**Risk:** high

**Phase hint:** 6

**Depends on:** DASH-024

**Serializes with:** BO-003, BO-005, BO-016, BO-019, DASH-002, DASH-012, DASH-019, DASH-026 — application supervision tree; the hard-ordered storage chain owns one destructive seam

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-025

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex-gpt-5.6-sol`, `phase:6`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Aiur bounds raw usage storage through crash-safe rotation, retention, and compaction while every DASH-024 query dimension, exact total, and retained-coverage fact survives deletion unchanged.

## Context and evidence

Raw append and aggregate correctness must be proven before old segments can be removed. This ticket owns the only destructive storage phase: it commits durable dimension-preserving aggregate coverage before deleting raw source, then proves replay/query consistency across every crash boundary.

## Scope

- Define configurable bounded segment rotation and retention policy with explicit size/time thresholds, minimum retained raw recovery window, and reported coverage.
- Before deleting any raw segment, commit a DASH-024-compatible compacted
  aggregate block preserving provider, run, typed ticket, attempt, backend,
  agent family, exact model, auth mode, account generation including unknown,
  UTC pricing-effective date, token dimension, `token_relationship_revision`
  including unknown, basis, currency, exact totals, gaps, and earliest/latest
  covered time.
- Use a versioned manifest/state machine for prepared, aggregate-committed, source-retired, and finalized phases. Flush/atomic rename/checksum every transition needed for crash recovery.
- Make DASH-024 queries combine compacted blocks plus live aggregates without duplicates or gaps and without changing public query semantics.
- Never merge different dates, currencies, bases, generations, models,
  identities, token dimensions, or token-relationship revisions during
  compaction.
- Quarantine inconsistent manifests/segments/blocks, preserve the last validated queryable state, and stop destructive progress until safe reconciliation.
- Expose retention policy, earliest/latest raw and aggregate coverage, compaction generation/status/health, and bounded operational evidence.
- Prove rollback/rebuild limits explicitly once raw segments are retired.

## Non-goals

- Change envelope/delta semantics, pricing, tier joins, UI, or introduce Postgres/Ecto/SQLite.
- Delete source before durable compacted coverage, silently widen/narrow retention, merge dimensions for space savings, or promise indefinite history.
- Add a second aggregate/query API or writer.

## Existing owner and reuse target

Extend DASH-009 segment and DASH-024 aggregate behaviors through one supervised compaction coordinator. Reuse private path, atomic/checksummed manifest, injected filesystem/clock/fault, and health conventions.

## Contract and invariants

- No source deletion precedes durable validated compacted coverage for its exact ledger range.
- Compacted plus live query results equal pre-compaction results for every scope and grouping dimension.
- Compacted blocks retain the exact token-relationship revision from DASH-024;
  unknown and distinct revisions remain separate before and after source
  retirement.
- Compaction is idempotent across duplicate/restarted phases and cannot double count a range.
- Retained coverage is explicit; expired data is never reported as zero or silently absent from a complete result.
- Destructive operations are owner-only, path-contained, and halt on ambiguity/corruption.

## Refreshable implementation notes

- Refresh final DASH-009 segment identity and DASH-024 aggregate position/block formats at pickup; use public seams rather than reaching into modules.
- Keep policy, manifest state machine, block codec, coordinator, and reconciliation modules independently testable.
- Choose defaults from measured event frequency/storage size, but make correctness independent of the chosen thresholds.
- Reconcile the central application supervision tree with every declared
  serialization peer before either overlapping branch executes or merges.

## Acceptance and verification

### Agent gate

- Property tests compact fixtures differing in every preserved dimension,
  including identical token rows under distinct known/unknown relationship
  revisions, and prove all scoped totals/groups/coverage remain identical and
  no revisions merge.
- Crash-boundary tests stop at prepared, aggregate write/flush/rename, manifest commit, source delete, and finalize; restart yields exactly one valid result or a safe halted state.
- Retention tests cover size/time thresholds, partial raw windows, multiple generations, repeated compaction, no eligible segments, corrupt blocks/manifests, disk/permission failures, and rollback limits.
- Security tests prove path containment, owner-only permissions, and content-free compacted data.

### At-merge gate

- Rebase on DASH-024 and the resolved configured integration target; run ledger, aggregate/query, rotation/retention, crash/fault, packaging/state-directory, security, performance, and full CI suites.

### Human/manual evidence

- Compact a synthetic multi-day/multi-account/multi-relationship-revision
  dataset, restart the daemon, and show byte-bounded raw storage plus identical
  DASH-024 totals/groups/revisions and explicit retained coverage.

## Failure, security, migration, and accessibility cases

- Any ambiguous/corrupt/destructive failure halts deletion, preserves validated query state, and reports health; it never resets totals or claims full coverage.
- Compacted data remains owner-only and content-free; no prompts, raw responses, credentials, PII, environment values, or paths.
- Version manifests/blocks and document upgrade/rollback after source
  retirement; migration never rewrites or coalesces historical
  token-relationship revisions.
- No direct UI; retention/coverage/health reasons are stable human-readable values.

## Surfaces

- Reads: DASH-009 segment ranges and DASH-024
  relationship-revision-partitioned aggregate/query/checkpoint behavior.
- Writes: rotation/retention policy, relationship-revision-preserving compacted
  aggregate blocks, destructive-phase manifest, segment retirement,
  health/coverage.
- Contracts: dimension- and token-relationship-revision-preserving compaction
  and retained-coverage semantics.
- Safety: no-delete-before-coverage, crash-safe destructive state machine,
  exact query equivalence, and the application supervision tree.

## Sibling boundaries and open gates

DASH-009 remains raw/delta authority and DASH-024 remains aggregate/query owner.
Declared serialization peers share only the central application supervision
tree. DASH-011 pricing semantics do not change. DASH-015 depends on this
hardening before presenting retained usage as production-ready.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-025`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

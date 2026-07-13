# DASH-006 — Add retained Decision lookup and queries

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 3 — Bounded direct-detail, cursor query, search, and canonical count contracts over the retained store

**Risk:** high

**Phase hint:** 1

**Depends on:** none

**Serializes with:** DASH-017 — shared Decision store modules

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-006

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:1`, `build-lane:runtime`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Commands consumers can resolve any retained Decision by stable ID, page and search the complete retained set with bounded payloads, and display canonical open/blocking counts independently of the priority-bounded overview.

## Context and evidence

Current `ControlCenterPresenter` loads a priority-bounded 50-Decision overview and `DashboardLive` searches that payload for direct detail even though `DecisionStore.get/2` exists. An older durable deep link can therefore appear missing, and overview length can be mistaken for a global count. DASH-017 separately owns trusted provenance schema changes while preserving existing supervisor basis, so query work is not coupled to a migration program.

## Scope

- Add an on-demand detail provider that calls `DecisionStore.get/2`, then applies the same sanitization, lifecycle, latency, health, and presenter composition as overview rows.
- Define a bounded cursor-based retained-Decision query for Commands `All` with stable audit ordering, validated page size, lifecycle filters, optional bounded ticket/Decision-ID search, and total/partial-result metadata.
- Keep priority-bounded overview, retained page/search, and exact detail as three explicit contracts; none may silently substitute for another.
- Expose canonical counts for open and blocking retained Decisions separately from bounded overview counts, including partial/unavailable health.
- Thread selected ID and page/search inputs through `PayloadLoader` or a dedicated provider without making every browser mount load all retained Decisions.
- Return DASH-017 provenance when present and the existing `supervisor_basis` unchanged; legacy unknown provenance remains a valid query result.

## Non-goals

- Change Decision schema, capture provenance, alter existing supervisor basis, migrate records, redesign Commands UI, rename the Decision domain, or change lifecycle/authority semantics.
- Load all Decisions into one LiveView payload, add free-form full-text indexing, or expose raw prompts/session/account data.
- Parse model, backend, confidence, question, rationale, or origin display text.

## Existing owner and reuse target

Extend `DecisionStore`, `DecisionApi`, `DecisionPresenter`, `ControlCenterPresenter`, and `PayloadLoader`. Reuse current audit ordering, bounded-query, sanitization, health, and cache patterns.

## Contract and invariants

- Direct lookup is exact by canonical Decision ID and independent of the overview window.
- Page/search cursors use stable retained-store ordering rather than offset semantics that drift under insertion.
- Search input, cursors, and page sizes are bounded and validated at the provider boundary.
- Overview, retained counts, page/search, and detail each declare scope and health. Partial data is never presented as complete global truth.
- Detail and list apply the same content sanitization and lifecycle vocabulary.

## Refreshable implementation notes

- Refresh current Decision store/version APIs and OCC provider boundaries at pickup; avoid broad refactors of the large store module.
- Prefer small query/provider modules under the repository size limits, with the existing store as a boundary rather than duplicating persistence.
- Coordinate file ownership with DASH-017; use `serializes_with`, not a false semantic dependency.

## Acceptance and verification

### Agent gate

- Store/provider tests cover an ID older than the newest 50, missing ID, cursor stability under concurrent inserts, lifecycle/search filters, bounded pages, canonical counts, partial/provider failure, and sanitization parity.
- Property tests cover invalid cursor/page/search inputs, stable ordering, no duplicates across pages, and exact direct lookup independent of overview cache.
- Security tests prove no prompt, raw session, account identity, credential, or untrusted display-derived field crosses the provider boundary.

### At-merge gate

- Rebase on the resolved configured integration target and sequence with DASH-017/active Decision work; run Decision store/API/history/metrics, presenter/cache/LiveView compatibility, security, and full CI suites.

### Human/manual evidence

- After DASH-007 consumes the contract, open a retained Decision outside the overview window by direct URL and navigate at least two `All` pages without losing filter/search state.

## Failure, security, migration, and accessibility cases

- Detail failure names absent versus unavailable and does not erase a healthy overview. Page/count failures retain scope and partial-health metadata.
- Preserve Decision sanitization and exclude raw prompts, sessions, account identity, credentials, and capability URLs.
- No stored-data migration belongs here. Query version compatibility must continue reading all retained supported Decision schemas.
- Provider output includes concise accessible labels for scope, count health, pagination, and unavailable reasons.

## Surfaces

- Reads: Decision store/audit, Decision metrics and existing presenters.
- Writes: direct-detail provider, retained cursor query/search/count APIs, provider composition and tests.
- Contracts: exact detail lookup, bounded retained query/search, canonical retained counts.

## Sibling boundaries and open gates

DASH-017 owns durable provenance fields/migration while preserving the existing supervisor-basis contract. DASH-007 owns Commands vocabulary, filters, cards, and actions. DASH-006 and DASH-017 serialize on shared Decision store/schema files but remain independently reviewable outcomes.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-006`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

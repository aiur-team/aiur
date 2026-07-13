# DASH-004 — Align Commands dashboard experience

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Presentation/route alignment over durable Decision lifecycle

**Risk:** high

**Depends on:** none

**Requirements:** DREQ-004

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

The dashboard uses the refreshed Commands vocabulary and primary organization while preserving every canonical Decision lifecycle state, durable history, deep link, confirmation, retry, revision, and follow-up behavior.

## Context and evidence

The mock simplifies primary filters to Open/Blocking/Resolved/All and changes the banner to `Issue commands`, but it drops blocking explanation and retains a pluralization bug. Current main intentionally bounds overview history to 50 while prioritizing unresolved/urgent records and requires authenticated fail-closed writes.

## Scope

- Adopt Commands page/nav/banner/card vocabulary and reviewed primary filters without renaming the internal Decision domain/store.
- Keep answered-not-delivered, supervising decisions, superseded, revisions, follow-ups, stale answers, delivery failures, and all durable states reachable through All/detail/history.
- Preserve URL filters, stable Decision deep links/on-demand lookup, bounded-overview partial-result messaging, and explicit blocking/nonblocking counts/context.
- Add source-backed provider/model origin, option previews, supervisor/selected-answer indicators, and recommendation confidence only when canonical fields exist.
- Fix singular/plural copy and preserve irreversible confirmation, sanitization, retry, revisions, follow-ups, and writable/auth gates.

## Non-goals

- Delete Decision history/lifecycle states, copy prototype quick Defer/Acknowledge actions, or migrate persistence names.
- Change Build Order providers, Units, or usage accounting.

## Existing owner and reuse target

Reuse `DecisionInbox`, `DecisionPresenter`, `DecisionHistory`, `DecisionStore`, Decision routes/API, and recent bounded-history/auth fixes.

## Contract and invariants

- Operator vocabulary may say Commands; canonical persistence and API semantics remain Decisions.
- Four primary filters may simplify entry, but no actionable/durable lifecycle state becomes unreachable.
- Counts declare when based on a retained window; direct detail lookup does not fail merely because a record falls outside 50.
- Mutation behavior remains versioned, confirmed, sanitized, authenticated, and fail closed.

## Refreshable implementation notes

- Refresh current bounded Decision APIs and open dashboard PRs at pickup.
- Keep filter/copy policy separate from lifecycle storage.

## Acceptance and verification

### Agent gate

- Decision presenter/LiveView tests cover primary filters, every secondary lifecycle state, deep links outside overview, partial counts, blocking banner, pluralization, origin metadata, and all mutation safeguards.
- Browser tests cover URL/back, keyboard/touch, confirmation/focus, retry/error, responsive layout, and read-only mode.

### At-merge gate

- Decision store/API/history/dashboard and current-base full CI pass without weakening recent auth/bounds.

### Human/manual evidence

- Reviewer resolves, revises, and revisits representative blocking and delivered Commands using deep links.

## Failure, security, migration, and accessibility cases

- Preserve secret redaction, sanitization, Basic/supervisor auth, CSRF/version conflict behavior.
- No store migration unless separately justified and replay-tested.
- Commands, filters, urgency, confirmation, and error states remain accessible and non-color-dependent.

## Surfaces

- Reads: canonical Decision projections/history/routes.
- Writes: Commands presentation/filter/banner components and tests.
- Contracts: Commands vocabulary/filter reachability and bounded-history semantics.

## Sibling boundaries and open gates

DASH-001 owns shell. Do not alter Build Order or Units data providers. Sequence shared DashboardLive/CSS edits.


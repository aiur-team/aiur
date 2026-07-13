# BO-002 — Fetch complete GitHub Build Order graphs

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Batched paginated GitHub graph reads with partial-failure semantics

**Risk:** high

**Phase hint:** 2

**Depends on:** BO-001

**Serializes with:** none

**Requirements:** BOREQ-001, BOREQ-002, BOREQ-003, BOREQ-004, BOREQ-009, BOREQ-012

**Decisions:** DEC-001, DEC-002, DEC-003, DEC-004, DEC-005

**Design evidence:** DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`, `phase:2`, `build-lane:backend`; never `agent:todo`

## Outcome

One adapter returns a complete candidate root catalog or selected-root graph, including identities, ticket facts, ordered membership, labels, outcomes, native blockers, and external references, with bounded GitHub calls and explicit failure.

## Context and evidence

Existing issue fetching drops GitHub node/database IDs, sub-issue order, and dependency detail. `Aiur.GitHub.DependenciesAPI` reads only one dependency page and converts some failure paths into shapes unsuitable for an authoritative 100-node graph.

Current GraphQL schema introspection confirms `Issue.parent`, `subIssues`, `blockedBy`, and `blocking`. The adapter must use those native relationships and preserve errors instead of turning an incomplete connection into an empty edge set.

## Scope

- Fetch an open root catalog by the constant `build-order` label and support direct lookup of a selected closed root for stable deep links.
- Fetch one selected root, its direct ordered sub-issues, labels, state/state reason, node/database/repository identities, body marker, and paginated `blockedBy` connections.
- Batch member/dependency hydration with GraphQL `nodes(ids)` or an equivalently bounded strategy; preserve external blocker identity and known outcome even when it is not a member card.
- Return structured candidate data and provider metadata without caching or mutating process state.
- Reject top-level GraphQL errors, field-level partial responses, page failures, count mismatches, ambiguous identities, and over-limit membership.
- Measure and assert a documented upper call/query-cost bound for 20, 50, and 100 members.

## Non-goals

- Own refresh cadence, last-known-good generations, PubSub, browser demand coalescing, or LiveView assigns.
- Write sub-issue/dependency relationships, reparent tickets, or edit labels.
- Fetch Aiur progress, logs, usage, commands, or provider billing.

## Existing owner and reuse target

Extend `Aiur.GitHub.Transport` conventions and reuse cursor/error patterns from the paginated review-thread clients. Do not extend the per-issue dispatch hydration path into an N+1 graph provider.

## Contract and invariants

- Catalog reads and selected-root reads are separate operations with separate errors and pagination.
- A successful result is complete by contract. Any unresolved page or partial GraphQL response is an error carrying retry/rate-limit context.
- Native direction is blocker to blocked. Only `blockedBy` relationships become hard edges; prose tables and `serializes_with` never do.
- The adapter returns canonical node IDs and mutable locators and never assumes issue-number adjacency.
- GitHub tokens, emails, raw headers, and full raw responses are not retained in returned records or logs.

## Refreshable implementation notes

- Refresh GitHub API fields and rate-limit budget at pickup; the researched schema may evolve.
- Likely seams include `src/lib/aiur/github/transport.ex` plus new `build_order/github_adapter*` modules and boundary fixtures.
- Keep queries and response normalization in separate modules to respect the 200-line file target.

## Acceptance and verification

### Agent gate

- Boundary tests cover empty catalog, multiple roots, selected closed root, root-with-parent, 100 children, pagination, ordering, external blockers, `COMPLETED`/`NOT_PLANNED`, duplicate metadata, and malformed marker preservation.
- Failure tests cover page two failure, partial GraphQL `errors`, missing node, rate limit, auth, timeout, over-limit count, and verify that no failure is returned as a successful empty edge list.
- Call-bound tests prove browser count is irrelevant and candidate fetches remain bounded at 20/50/100 nodes.

### At-merge gate

- Current-base GitHub adapter tests and full CI pass with synthetic fixtures and no live-token dependency.
- The selected API fields are rechecked against current GitHub schema and deviations are recorded in the PR.

### Human/manual evidence

- No separate human evidence; BO-011 owns end-to-end operator proof.

## Failure, security, migration, and accessibility cases

- Security: redact credentials and account/user identifiers and allow only configured repository identities in v1.
- Migration: no persistent data is written.
- Accessibility: no direct UI; retain enough diagnostic detail for an understandable provider failure.

## Surfaces

- Reads: GitHub GraphQL issue/sub-issue/dependency API; Build Order domain contract; GitHub transport/error conventions.
- Writes: Build Order GitHub adapter; GraphQL fixtures and adapter tests.
- Contracts: complete root catalog candidate; complete selected-root graph candidate; bounded call and error contract.

## Sibling boundaries and open gates

BO-003 owns caching and refresh. BO-001 owns parsing policies. BO-006 owns readiness/presentation. Issue publication later uses write APIs but is not part of this read adapter.


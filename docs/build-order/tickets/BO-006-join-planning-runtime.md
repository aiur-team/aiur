# BO-006 — Join planning and runtime state

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Pure presenter and graph diagnostics over two snapshots

**Risk:** high

**Phase hint:** 3

**Depends on:** BO-001, BO-004

**Serializes with:** none

**Requirements:** BOREQ-003, BOREQ-006, BOREQ-008, BOREQ-009

**Decisions:** DEC-001, DEC-003, DEC-006, DEC-010

**Design evidence:** DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:3`, `model:codex`, `phase:3`, `build-lane:backend`; never `agent:todo`

## Outcome

A pure presenter converts one validated GitHub graph plus one activity snapshot into truthful cards, directed edges, adjacency, readiness, diagnostics, counts, and freshness without performing I/O.

## Context and evidence

The UI must not decide precedence by whichever provider field is easiest to render. GitHub lifecycle/dependencies and Aiur activity have distinct authority, freshness, and failure semantics.

This presenter is the stable seam for ticket context, graph rendering, tests, and future consumers. It can be built from fixtures before the supervised GitHub projection lands.

## Scope

- Join on typed tracker/repository identity and canonical GitHub node mapping, preserving unmatched GitHub members and diagnosing unmatched activity.
- Derive cards with separate plan, lifecycle, readiness, activity, progress, and provider-health subrecords.
- Derive blocker-to-blocked edges, upstream/downstream adjacency, strongly connected components, external/missing references, and graph-quality warnings.
- Apply terminal/readiness/status precedence without allowing runtime progress or agent labels to override GitHub outcomes.
- Group arbitrary positive phases and controlled lanes with Unphased/Unassigned fallbacks and deterministic icon keys.
- Return stable ordering, counts, and freshness suitable for LiveView diffing; perform no fetch, mutation, log parse, or missing-value default.

## Non-goals

- Choose coordinates, route SVG paths, run JavaScript, or render HEEx.
- Own provider polling/caching or TicketActivity reduction.
- Filter away invalid/external/cyclic facts merely to make the graph visually simpler.

## Existing owner and reuse target

Add a dedicated Build Order presenter rather than overloading `AiurWeb.Presenter`, whose current payload is fleet/API-oriented. Reuse pure graph algorithms/helpers when an existing implementation is actually compatible.

## Contract and invariants

- GitHub terminal outcome outranks runtime overlay; runtime activity never clears an edge.
- Missing or stale activity yields unknown activity/progress while GitHub planning facts remain visible.
- Any unavailable/stale dependency generation prevents readiness from becoming ready.
- Cycles are explicit SCC diagnostics; external/missing references remain represented.
- Output is deterministic for the same two snapshots and safe to serialize into LiveView assigns.

## Refreshable implementation notes

- Likely modules live under `Aiur.BuildOrder.Presenter` and small graph-policy helpers.
- Keep Tarjan/topological helpers pure and bounded at 100 members.
- Use synthetic fixtures shared with BO-007/010 only through stable test support, not production coupling.

## Acceptance and verification

### Agent gate

- Table tests cover no activity, stale activity, active/paused/retrying/completed runtime, GitHub completed/not-planned/open, conflicting agent labels, external blockers, missing endpoints, cycles/self-loop, invalid metadata, arbitrary phases, and stable ordering.
- Tests prove Aiur 100% cannot clear an open GitHub blocker and provider failure cannot produce a ready/empty graph.
- Presenter tests run without GitHub, processes, filesystem, or browser.

### At-merge gate

- Pure presenter/graph tests, specs/lint, and current-base full CI pass.
- Snapshot contract examples are documented for BO-008/009.

### Human/manual evidence

- No separate human evidence; BO-011 owns end-to-end operator proof.

## Failure, security, migration, and accessibility cases

- Security: pass through only normalized safe URLs and redacted provider errors.
- Migration: new presenter; no stored data.
- Accessibility: preserve full titles, relationship text, status reasons, and deterministic semantic ordering for the DOM.

## Surfaces

- Reads: Build Order graph snapshot contract; TicketActivity snapshot.
- Writes: pure Build Order presenter; graph policy tests.
- Contracts: BuildOrderViewModel; edge/readiness/status precedence; adjacency and diagnostics.

## Sibling boundaries and open gates

BO-008 consumes member context from this presenter. BO-009 renders the graph. BO-003 owns freshness truth; the presenter only interprets it.


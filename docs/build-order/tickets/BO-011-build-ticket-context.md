# BO-011 — Adapt ticket context to Build Order

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Bounded Build Order relationship adapter and root-scoped focus policy over established contracts

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-007, BO-008, BO-016

**Serializes with:** none

**Requirements:** BOREQ-011

**Decisions:** DEC-003, DEC-008, DEC-009

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex`, `phase:4`, `build-lane:frontend`; never `agent:todo`

## Outcome

Build Order composes BO-016's repository-qualified base ticket context with
BO-007's truthful adjacency and edge diagnostics, so an Executor can inspect
and navigate one root-scoped selection with deterministic focus while the graph
remains strictly read-only.

## Context and evidence

BO-016 deliberately provides ticket detail, caching, safe links, and an
accessible base component without knowing that a ticket belongs to a Build
Order. BO-007 separately owns graph relationships, edge states, readiness, and
diagnostics. Combining those concerns in either owner would make a reusable
ticket context depend on a root graph or would let the web layer recompute
planning truth.

The prototype hard-codes repository links and drops external or missing
endpoints. It also treats selection and hover as client-only state. This ticket
is the narrow Build Order adapter: it owns relationship presentation,
root-scoped selection/focus, and enforcement of the feature's read-only graph
policy, but it does not fetch or cache ticket detail and does not own the base
context component.

## Scope

- Define a pure Build Order context adapter over BO-007's selected-node,
  upstream/downstream adjacency, edge-state, readiness, provider, activity, and
  diagnostic values plus BO-016's repository-qualified base-context snapshot.
  Rendering performs no provider, filesystem, log, clock, or process lookup.
- Open BO-016's base context using the exact selected member identity. Preserve
  its loading, available, stale, unavailable, bounded-content, safe-link, and
  all-state semantics without copying its provider/cache policy into LiveView.
- Add named `Blocked by` and `Blocking` relationship sections with direction,
  edge state, readiness impact, and external/missing/cyclic/
  terminal-unsatisfied diagnostics exactly as supplied by BO-007.
- Support relationship replacement navigation only when an endpoint has a
  trusted repository-qualified identity. Missing endpoints remain diagnostic;
  external endpoints never become members of the selected root implicitly.
- Key selection to canonical root, graph generation, and ticket identity.
  Clear or reconcile it deterministically on root/generation change, focus the
  replacement heading after relationship navigation, and restore focus to the
  originating graph card when context closes.
- Preserve validated safe GitHub and existing destination links exposed by
  BO-016. Navigation is not evidence that a destination action succeeded.
- Enforce the Build Order read-only policy at the adapter boundary: expose no
  event handler for GitHub membership, labels, phase, lane, lifecycle, or
  dependencies and no handler for chat, Decisions, pause/resume, capacity, or
  any other Aiur mutation.

## Non-goals

- Fetch GitHub ticket detail, own provider scheduling/LKG/cache state, sanitize
  issue bodies, or implement the reusable accessible base context component.
- Recompute adjacency, SCCs, edge/readiness policy, activity joins, or provider
  health outside BO-007.
- Own catalog/root URLs, the graph route, card rendering, pan/zoom, or final
  interaction hardening.
- Add Build Order relationship assumptions or mutation controls to BO-016.

## Existing owner and reuse target

Compose BO-016's base `TicketContext` contract with BO-007's bounded
`BuildOrderViewModel` relationship values. Reuse current dashboard dialog/focus
and route-link conventions through those contracts; do not fork the generic
provider/cache/component or the graph presenter.

## Contract and invariants

- The adapter accepts normalized cached inputs only. BO-016 is the sole owner
  of selected-ticket provider demand, detail health, content bounds, and cache.
- Relationship direction, edge state, readiness, and diagnostics are passed
  through from BO-007 unchanged; the component cannot clear or reclassify an
  edge.
- A selected root member and the base-context snapshot must share the exact
  repository-qualified identity. Bare numbers, titles, topics, and local paths
  never join them.
- Context replacement never mutates root membership. An external endpoint may
  be inspected only as a separately qualified ticket; a missing endpoint stays
  unavailable and diagnostic.
- Selection/focus state is scoped to root plus generation. Stale provider
  completion, LiveView patch, reconnect, or root switch cannot reopen or apply
  context for the previous root.
- Build Order behavior remains read-only. Safe destination availability is a
  normalized capability checked again by the destination; this adapter has no
  mutation event handler.

## Refreshable implementation notes

- Refresh BO-007 and BO-016 public shapes plus current dashboard dialog/focus
  helpers on the configured integration branch before naming the adapter.
- Prefer a small pure adapter and root-scoped selection reducer; BO-012 should
  wire them rather than recreate relationship/focus policy in LiveView assigns.
- Exercise the composition through BO-008's real-browser harness. Do not add a
  browser-only cache or widen graph-card/worker payloads with issue bodies.

## Acceptance and verification

### Agent gate

- Pure/component tests cover both relationship directions, all five edge
  states, external/missing/cyclic/terminal-unsatisfied endpoints, metadata
  warnings, every BO-016 detail-health state, and exact identity matching.
- Selection tests cover root and generation changes, removed members, delayed
  stale detail completion, relationship replacement/back, LiveView reconnect,
  heading focus, Escape/close, and origin focus restoration.
- Integration tests prove detail demand remains coalesced in BO-016, opening
  context never hydrates every graph member, and BO-007 relationship values are
  neither recomputed nor rewritten.
- Security tests prove only validated safe links render and no GitHub,
  Decision, chat, pause/resume, capacity, or other mutation handler exists.

### At-merge gate

- Build Order presenter, base context/provider, route-link, auth/security,
  accessibility, browser, compile/lint/spec, and full repository CI pass on the
  current configured integration branch.
- BO-012 consumes this adapter rather than duplicating relationship, selection,
  focus, or read-only policy.

### Human/manual evidence

- Reviewer uses keyboard only to open a running, completed, invalid, and
  external ticket; follows both relationship directions; changes roots while
  context is open; closes it; and confirms focus and safe navigation behavior.
  BO-015 owns final integrated proof.

## Failure, security, migration, and accessibility cases

- Treat identity mismatch and stale generations as unavailable selection, not
  permission to guess. Never render raw provider errors, unsafe URLs, local
  paths, credentials, capability URLs, account data, or unbounded content.
- No stored-data migration is introduced; root-scoped selection is disposable.
- Use semantic relationship headings/lists/buttons, non-color edge status,
  deterministic heading/origin focus, minimum touch targets, and concise named
  loading/error states across LiveView patches.

## Surfaces

- Reads: BO-007 selected-node relationship model; BO-016 repository-qualified
  base ticket context; BO-008 browser/accessibility harness.
- Writes: Build Order TicketContext adapter; root-scoped selection/focus and
  read-only graph-policy tests.
- Contracts: Build Order relationship context adapter; root/generation-scoped
  selection and focus; no-mutation graph boundary.

## Sibling boundaries and open gates

BO-016 owns provider/cache/base context, BO-007 owns graph truth, and BO-012
wires the route. BO-013 hardens canvas-wide interaction while preserving this
adapter's context focus and read-only policy. A Units companion may reuse
BO-016, but must not import this Build Order relationship adapter or add action
controls through it.

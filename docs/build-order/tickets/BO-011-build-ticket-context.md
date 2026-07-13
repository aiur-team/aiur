# BO-011 — Adapt ticket context to Build Order

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Build Order relationship diagnostics, destination binding, and root-scoped focus policy over established contracts

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-007, BO-018

**Serializes with:** none

**Requirements:** BOREQ-011

**Decisions:** DEC-003, DEC-008, DEC-009

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex`, `phase:4`, `build-lane:frontend`; never `agent:todo`

## Outcome

Build Order composes BO-018's accessible base ticket context with BO-007's
truthful adjacency/edge diagnostics and concrete read-only GitHub, Chat, and
Commands destination capabilities, so one root-scoped selection remains
truthful, focused, and non-mutating.

## Context and evidence

BO-018 deliberately provides detail/history presentation, Logs, normalized
CTAs, and accessible base focus without knowing that a ticket belongs to a
Build Order. BO-007 separately owns graph relationships, edge states, readiness,
runtime joins, and diagnostics. This adapter binds those contracts to actual
dashboard destination routes without letting the web layer recompute truth.

The prototype hard-codes repository links and drops external or missing
endpoints. It also treats selection and hover as client-only state. This ticket
is the narrow Build Order adapter: it owns relationship presentation,
root-scoped selection/focus, and enforcement of the feature's read-only graph
policy/destination eligibility, but it does not fetch detail/history and does
not own the base context component.

## Scope

- Define a pure Build Order context adapter over BO-007's selected-node,
  upstream/downstream adjacency, edge-state, readiness, provider, activity, and
  diagnostic values plus BO-018's base-context/CTA inputs.
  Rendering performs no provider, filesystem, log, clock, or process lookup.
- Open BO-018's base context using the exact configured-repository selected
  member identity. Preserve its detail/history/loading/stale/missing/restart,
  bounded Logs, and all-state semantics without copying providers into LiveView.
- Add named `Blocked by` and `Blocking` relationship sections with direction,
  edge state, readiness impact, and external/missing/cyclic/
  terminal-unsatisfied diagnostics exactly as supplied by BO-007.
- Support relationship replacement navigation only when an endpoint has a
  trusted repository-qualified identity. Missing endpoints remain diagnostic;
  other-repository endpoints remain nonfetchable diagnostics and never become
  selected members. A validated external GitHub URL may render only as an
  outbound diagnostic link, not context selection or a destination capability.
- Key selection to canonical root, graph generation, and ticket identity.
  Clear or reconcile it deterministically on root/generation change, focus the
  replacement heading after relationship navigation, and restore focus to the
  originating graph card when context closes.
- Bind normalized CTA capabilities concretely: GitHub only for the selected
  configured-repository issue's safe canonical URL; Chat only for an exact
  active/readable selected-member chat route; Commands only for an exact
  selected-member readable command/Decision destination. Missing/stale/
  unauthorized destinations render unavailable with reason. Navigation is not
  evidence that a destination action succeeded.
- Enforce the Build Order read-only policy at the adapter boundary: expose no
  event handler for GitHub membership, labels, phase, lane, lifecycle, or
  dependencies and no handler for chat, Decisions, pause/resume, capacity, or
  any other Aiur mutation.

## Non-goals

- Fetch GitHub ticket detail, own detail/history provider/cache state, sanitize
  issue/log content, or implement the reusable accessible base component.
- Recompute adjacency, SCCs, edge/readiness policy, activity joins, or provider
  health outside BO-007.
- Own catalog/root URLs, the graph route, card rendering, pan/zoom, or final
  interaction hardening.
- Add Build Order relationship assumptions or concrete route eligibility to
  BO-018.

## Existing owner and reuse target

Compose BO-018's base `TicketContext`/CTA contract with BO-007's bounded
`BuildOrderViewModel` relationship values. Reuse current dashboard dialog/focus
and concrete GitHub/Chat/Commands route-link conventions; do not fork generic
providers/base component or the graph presenter.

## Contract and invariants

- The adapter accepts normalized cached inputs only. BO-016/019 remain the sole
  detail/history provider owners and BO-018 owns base rendering.
- Relationship direction, edge state, readiness, and diagnostics are passed
  through from BO-007 unchanged; the component cannot clear or reclassify an
  edge.
- A selected root member and the base-context snapshot must share the exact
  repository-qualified identity. Bare numbers, titles, topics, and local paths
  never join them.
- Context replacement never mutates root membership. An external endpoint may
  expose a validated outbound diagnostic link but is never fetched/selected;
  a missing endpoint stays unavailable and diagnostic.
- Selection/focus state is scoped to root plus generation. Stale provider
  completion, LiveView patch, reconnect, or root switch cannot reopen or apply
  context for the previous root.
- Build Order behavior remains read-only. Safe destination availability is a
  normalized capability checked again by the destination; this adapter has no
  mutation event handler.

## Refreshable implementation notes

- Refresh BO-007/018 public shapes plus current GitHub, Chat, Commands,
  auth/route and dialog/focus helpers on the configured branch.
- Prefer a small pure adapter and root-scoped selection reducer; BO-012 should
  wire them rather than recreate relationship/focus policy in LiveView assigns.
- Exercise the composition through BO-008's real-browser harness. Do not add a
  browser-only cache or widen graph-card/worker payloads with issue bodies.

## Acceptance and verification

### Agent gate

- Pure/component tests cover both relationship directions, all five edge
  states, external/missing/cyclic/terminal-unsatisfied endpoints, metadata
  warnings, every BO-018 detail/history state, and exact identity matching.
- Selection tests cover root and generation changes, removed members, delayed
  stale detail completion, relationship replacement/back, LiveView reconnect,
  heading focus, Escape/close, and origin focus restoration.
- Destination tests prove exact GitHub/Chat/Commands available and unavailable
  cases, stale/missing/unauthorized reasons, other-repository nonfetchable
  diagnostics, and optional safe outbound external GitHub link semantics.
- Integration tests prove opening context never hydrates every graph member or
  parses logs, and BO-007/018 values are neither recomputed nor rewritten.
- Security tests prove only validated navigation links render and no GitHub,
  Decision, chat, pause/resume, capacity, or other mutation handler exists.

### At-merge gate

- Build Order presenter, detail/history/base context, route-link, auth/security,
  accessibility, browser, compile/lint/spec, and full repository CI pass on the
  current configured integration branch.
- BO-012 consumes this adapter rather than duplicating relationship, selection,
  focus, or read-only policy.

### Human/manual evidence

- Reviewer uses keyboard only to open a running, completed, invalid, and
  external ticket; follows both relationship directions; changes roots while
  context is open; exercises available/unavailable GitHub, Chat, and Commands
  destinations plus an other-repository diagnostic; closes it; and confirms
  focus and navigation-only behavior. BO-015 owns final integrated proof.

## Failure, security, migration, and accessibility cases

- Treat identity mismatch and stale generations as unavailable selection, not
  permission to guess. Never render raw provider errors, unsafe URLs, local
  paths, credentials, capability URLs, account data, or unbounded content.
- No stored-data migration is introduced; root-scoped selection is disposable.
- Use semantic relationship headings/lists/buttons, non-color edge status,
  deterministic heading/origin focus, minimum touch targets, and concise named
  loading/error states across LiveView patches.

## Surfaces

- Reads: BO-007 selected-node relationship/capability model; BO-018 accessible
  base context/CTA model; concrete GitHub/Chat/Commands route capabilities.
- Writes: Build Order TicketContext adapter; root-scoped selection/focus and
  read-only graph-policy tests.
- Contracts: Build Order relationship context adapter; truthful destination
  binding; root/generation-scoped selection/focus; no-mutation graph boundary.

## Sibling boundaries and open gates

BO-016/019 own detail/history, BO-018 owns base context, BO-007 owns graph and
runtime capability truth, and BO-012 wires the route. BO-013 hardens
canvas-wide interaction while preserving this adapter. Other surfaces may reuse
BO-018 but must bind their own destinations/actions elsewhere.

# BO-007 — Join planning and runtime state

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Pure graph-wide join, SCC analysis, and truthful presentation policy

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-001, BO-003, BO-005

**Serializes with:** none

**Requirements:** BOREQ-003, BOREQ-006, BOREQ-007

**Decisions:** DEC-001, DEC-003, DEC-006, DEC-010

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex`, `phase:4`, `build-lane:plan-graph`; never `agent:todo`

## Outcome

A pure presenter joins one complete GitHub planning snapshot with one typed
orchestrator status snapshot and one typed event-activity snapshot into bounded
root, node, edge, group, diagnostic, context, and summary models without I/O or
guessed defaults.

## Context and evidence

GitHub and Aiur own different facts. Combining them in LiveView assigns or
JavaScript would spread precedence and failure semantics across render paths.
The graph also needs whole-generation SCC analysis, external endpoint handling,
and reverse adjacency before layout or ticket context can consume it.

## Scope

- Join members to orchestrator status and event activity only by exact trusted
  repository-qualified tracker identity. Retain separate `plan`, `execution`,
  and `activity` subrecords plus provenance, health, and observation times.
- Compute directed adjacency, reverse adjacency, self-loops/strongly connected
  components, external/missing references, and bounded graph diagnostics.
- Distinguish configured-repository endpoints from other-repository endpoints.
  The latter remain nonfetchable external diagnostics with an optional
  validated outbound GitHub link; they never join runtime activity or become
  selected-root members.
- Classify edges exactly as `cleared`, `blocking`, `terminal_unsatisfied`,
  `unknown`, or `cyclic` and derive member readiness using `cyclic > unknown >
  terminal_unsatisfied > blocking > ready`.
- Apply state precedence without collapsing fields: GitHub terminal outcome,
  dependency/readiness, Aiur execution overlay, progress, active agent stage,
  and planned phase/lane remain independently inspectable.
- Produce deterministic lane/phase groups with Unassigned/Unphased fallbacks,
  node summaries, accessible edge/status text, root/catalog health, and counts
  that use the same policies as visible nodes.
- Derive Aiur-owned lane-icon and status-icon keys from BO-001 normalized lane,
  lifecycle/readiness, and runtime overlay using one explicit precedence table.
  Unknown values use the generic accessible fallback; no GitHub icon metadata
  or prototype icon value is consumed.
- Produce a body-free card model and selected-node relationship model from the
  normalized cached graph and activity snapshots. Full descriptions, generic
  ticket detail, and safe destination links remain outside this presenter.
- Preserve member metadata warnings as renderable diagnostics and distinguish
  selected structural-invalid from stale LKG, provider unavailable, and empty
  valid graphs.

## Non-goals

- Fetch GitHub, subscribe to PubSub, store LiveView assigns, parse logs, perform
  layout, render HTML/SVG, or invoke an Aiur runtime action.
- Change GitHub planning facts from Aiur progress or execution state.
- Hide invalid/missing members or select one duplicate planning label silently.

## Existing owner and reuse target

Reuse pure presentation conventions in `AiurWeb.ControlCenterPresenter` where
they fit, but keep Build Order graph/state policy in a bounded pure module.
Consume BO-001 domain records, BO-004-identified StatusReport snapshots, and
BO-005 event-activity snapshots directly.

## Contract and invariants

- The presenter is deterministic and total over bounded normalized inputs and
  performs no process, network, filesystem, clock, or configuration lookup.
- Aiur `100%` never clears an open GitHub blocker. `NOT_PLANNED` remains
  terminal-unsatisfied. Missing/stale dependencies remain unknown.
- Cyclic classification wins over every lesser readiness state for members in
  an SCC; edge and member status remain distinct.
- A missing StatusReport or activity match changes only the corresponding
  execution or activity subrecord to unknown.
- Other-repository endpoints never join BO-004/005 activity and never become
  eligible for BO-016 detail I/O; their diagnostic/link state stays explicit.
- Icon keys are deterministic derived presentation values and never override
  the accessible status text, lane, lifecycle, readiness, or activity facts.
- Cards and selected-node relationship values remain body-free and bounded;
  BO-016 separately owns on-demand generic ticket detail and its cache.

## Refreshable implementation notes

- Use pure Tarjan/topological/adjacency helpers bounded to 100 members and
  deterministic ordering independent of map iteration.
- Separate policy modules from web components so BO-011/012 can consume the
  same values and tests can exhaust state combinations.
- Keep safe destination capabilities as supplied normalized facts. Build Order
  invokes no mutating runtime action; companions own their action protocols.

## Acceptance and verification

### Agent gate

- Exhaustive tables cover all five edge states, readiness precedence, mixed
  blocker outcomes, SCC/self-loop/external/missing cases, terminal/runtime
  combinations, activity missing/stale, and duplicate metadata warnings.
- Identity tests prove same issue numbers in different repositories never join.
- Snapshot/property tests prove deterministic grouping/adjacency and bounded
  body-free card output at 0/1/20/50/100 nodes.
- Icon/cross-repository tests prove every normalized lane/status combination,
  generic fallbacks, no GitHub icon input, exact configured-repository joins,
  and nonfetchable other-repository diagnostics with only validated links.

### At-merge gate

- Presenter/domain/activity tests, compile/lint/spec checks, and full CI pass on
  the current configured integration branch.
- BO-011/012 public input contracts are reconciled before those consumers land.

### Human/manual evidence

- None separately; BO-015 proves the joined states against real and synthetic
  graphs.

## Failure, security, migration, and accessibility cases

- Do not propagate raw provider errors, issue bodies into cards, credentials,
  local paths, or untrusted action URLs.
- Pure new records introduce no stored migration; version public shapes if
  later persisted.
- Every status/diagnostic has accessible non-color text and deterministic
  ordering for screen-reader summaries.

## Surfaces

- Reads: BO-001 planning records, BO-003 catalog/selected-graph snapshots,
  BO-004-identified StatusReport snapshots, and BO-005 TicketActivity
  snapshots.
- Writes: pure BuildOrderPresenter policies, joined view/context models,
  adjacency/SCC helpers, and tests.
- Contracts: BuildOrderViewModel; body-free card and selected-node relationship
  input; edge/readiness/diagnostic precedence; derived lane/status icon keys;
  configured-versus-external repository policy.

## Sibling boundaries and open gates

BO-016 owns configured-repository detail/cache, BO-019 owns bounded history,
BO-018 owns accessible base context, and BO-011 adapts that context to this
ticket's adjacency/diagnostics and destination capabilities. BO-012 owns route
rendering; layout tickets consume geometry-only inputs. Companion Units may
reuse generic context/activity contracts but cannot change this graph join.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-007`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

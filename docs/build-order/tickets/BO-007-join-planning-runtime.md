# BO-007 — Join planning and runtime state

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Pure graph-wide join, SCC analysis, and truthful presentation policy

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-001, BO-005

**Serializes with:** none

**Requirements:** BOREQ-003, BOREQ-006, BOREQ-007

**Decisions:** DEC-001, DEC-003, DEC-006, DEC-010

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5

**Suggested labels:** `complexity:4`, `model:codex`, `phase:4`, `build-lane:backend`; never `agent:todo`

## Outcome

A pure presenter joins one complete GitHub planning snapshot with one typed Aiur
activity snapshot into bounded root, node, edge, group, diagnostic, context, and
summary models without I/O or guessed defaults.

## Context and evidence

GitHub and Aiur own different facts. Combining them in LiveView assigns or
JavaScript would spread precedence and failure semantics across render paths.
The graph also needs whole-generation SCC analysis, external endpoint handling,
and reverse adjacency before layout or ticket context can consume it.

## Scope

- Join members to activity only by exact trusted repository-qualified tracker
  identity. Retain separate `plan` and `activity` subrecords plus provenance,
  health, and observation times.
- Compute directed adjacency, reverse adjacency, self-loops/strongly connected
  components, external/missing references, and bounded graph diagnostics.
- Classify edges exactly as `cleared`, `blocking`, `terminal_unsatisfied`,
  `unknown`, or `cyclic` and derive member readiness using `cyclic > unknown >
  terminal_unsatisfied > blocking > ready`.
- Apply state precedence without collapsing fields: GitHub terminal outcome,
  dependency/readiness, Aiur execution overlay, progress, active agent stage,
  and planned phase/lane remain independently inspectable.
- Produce deterministic lane/phase groups with Unassigned/Unphased fallbacks,
  node summaries, accessible edge/status text, root/catalog health, and counts
  that use the same policies as visible nodes.
- Produce a body-free card model and a selected-ticket context model from
  normalized cached snapshots. Full descriptions and safe action capabilities
  remain out of the graph-card payload.
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
Consume BO-001 domain records and BO-005 activity snapshots directly.

## Contract and invariants

- The presenter is deterministic and total over bounded normalized inputs and
  performs no process, network, filesystem, clock, or configuration lookup.
- Aiur `100%` never clears an open GitHub blocker. `NOT_PLANNED` remains
  terminal-unsatisfied. Missing/stale dependencies remain unknown.
- Cyclic classification wins over every lesser readiness state for members in
  an SCC; edge and member status remain distinct.
- A missing activity match changes only the activity subrecord to unknown.
- Cards remain body-free and bounded; selected context uses already-cached
  normalized values rather than render-time provider reads.

## Refreshable implementation notes

- Use pure Tarjan/topological/adjacency helpers bounded to 100 members and
  deterministic ordering independent of map iteration.
- Separate policy modules from web components so BO-011/012 can consume the
  same values and tests can exhaust state combinations.
- Keep context action capabilities as supplied normalized facts; invocation
  and confirmation remain owned by the existing runtime action boundary.

## Acceptance and verification

### Agent gate

- Exhaustive tables cover all five edge states, readiness precedence, mixed
  blocker outcomes, SCC/self-loop/external/missing cases, terminal/runtime
  combinations, activity missing/stale, and duplicate metadata warnings.
- Identity tests prove same issue numbers in different repositories never join.
- Snapshot/property tests prove deterministic grouping/adjacency and bounded
  body-free card output at 0/1/20/50/100 nodes.

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

- Reads: BO-001 planning snapshots; BO-005 TicketActivity snapshots.
- Writes: pure BuildOrderPresenter policies, joined view/context models,
  adjacency/SCC helpers, and tests.
- Contracts: BuildOrderViewModel; card/context input; edge/readiness and
  diagnostic precedence.

## Sibling boundaries and open gates

BO-011 owns context UI, BO-012 owns routing/minimum rendering, and layout
tickets consume geometry-only inputs. Companion Units may reuse the context or
activity models, but does not change this graph join or hard dependencies.

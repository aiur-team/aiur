# BO-010 — Build DOM/SVG layout adapter and fallback

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Generation-safe DOM measurement, worker orchestration, SVG routing, and fallback

**Risk:** high

**Phase hint:** 3

**Depends on:** BO-008, BO-009

**Serializes with:** none

**Requirements:** BOREQ-008, BOREQ-009, BOREQ-010

**Decisions:** DEC-007

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5

**Suggested labels:** `complexity:4`, `model:codex`, `phase:3`, `build-lane:frontend`; never `agent:todo`

## Outcome

A single browser adapter measures semantic server-rendered cards, requests
geometry from BO-009's worker, applies card positions and accessible SVG edge
paths only to the matching generation, and preserves a deterministic readable
fallback whenever measurement, worker, or geometry fails.

## Context and evidence

The engine cannot measure real card content or safely apply late responses.
LiveView patches, fonts, viewport changes, root switches, and worker errors can
all invalidate geometry. Without one ownership boundary, stale layouts can be
painted onto a new root or semantic DOM can disappear behind a failed canvas.

## Scope

- Define one LiveView hook/adapter that discovers bounded semantic card and edge
  identifiers, measures cards/headers/lane/phase constraints, and sends only
  geometry inputs through BO-009's worker protocol.
- Tag every request with root identity, provider generation, DOM/layout
  generation, measurement version, and viewport facts; discard late or
  mismatched responses without visible rollback.
- Apply returned node coordinates and routed edge points to CSS positioning and
  a pointer-agnostic SVG layer while leaving cards in accessible DOM order.
- Render edge markers/styles from supplied `cleared`, `blocking`,
  `terminal_unsatisfied`, `unknown`, and `cyclic` state; geometry never
  reclassifies them.
- Provide deterministic, readable lane-by-phase document-flow fallback with an
  accessible dependency summary when Worker, engine, measurement, or response
  validation fails or JavaScript is unavailable.
- Handle initial fonts/measurements and LiveView patch lifecycle without leaks,
  duplicate hooks, missing cards, or hidden content. Expose safe layout health
  and timing observations for BO-014.
- Use BO-008 fixtures/helpers for real hook/worker/fallback browser coverage.

## Non-goals

- Fetch data, construct the joined view model, implement route selection,
  ticket context, pan/zoom/selection interactions, or final responsive/performance
  tuning.
- Reorder semantic DOM to match visual coordinates, place cards on a
  canvas-only surface, or hide the graph during failure.
- Own the third-party engine asset/version or interpret issue body content.

## Existing owner and reuse target

Extend the current LiveView JS hook/static asset conventions and dashboard CSS,
consuming only BO-009's worker protocol and BO-008's browser infrastructure.
Keep the adapter isolated behind stable DOM data attributes/events for BO-012.

## Contract and invariants

- Server-rendered cards and text dependency summaries remain meaningful before
  the hook runs and after any JavaScript/layout failure.
- A response applies only when root, data generation, DOM generation,
  measurement, and active hook instance all match.
- Semantic DOM/tab order is authored independently of visual coordinates;
  screen readers do not traverse SVG paths as duplicated content.
- Unknown/missing endpoints and cycles retain diagnostics even if no full edge
  path can be drawn.
- Geometry failure changes layout health/fallback only; it never changes node,
  edge, lifecycle, progress, or readiness truth.

## Refreshable implementation notes

- Refresh LiveView hook lifecycle, asset pipeline, and dashboard component/CSS
  ownership on the configured integration branch before choosing DOM events and
  data attributes.
- Keep measurement and response validation pure where possible; use observers
  only for lifecycle detection. BO-014 owns coalescing/budget hardening.
- Avoid pixel snapshots as sole assertions; test geometry invariants and
  accessible fallback content.

## Acceptance and verification

### Agent gate

- Unit tests cover measurement validation, root/generation mismatch, late
  responses, missing card/endpoint, malformed geometry, worker error/timeout,
  hook destroy/reconnect, and deterministic fallback.
- BO-008 browser tests prove real worker geometry, semantic DOM order, SVG
  marker/state classes, fallback without Worker/JS, LiveView patch recovery,
  no duplicate hooks, and no inaccessible duplicated edge content.
- Tests exercise all five edge states and prove geometry never clears or drops
  an unknown/cyclic/terminal-unsatisfied dependency.

### At-merge gate

- Hook/worker/static/component/browser/accessibility tests and full repository
  CI pass on the current configured integration branch.
- The adapter works from packaged local assets and leaves no worker/observer
  after view teardown.

### Human/manual evidence

- Reviewer compares normal worker and forced-fallback graphs with keyboard and
  screen-reader inspection. BO-015 owns full real-route evidence.

## Failure, security, migration, and accessibility cases

- Validate and bound every DOM/worker value; do not use issue content as HTML,
  CSS selectors, or worker diagnostics.
- No persisted migration; hook and worker protocol versions fail visibly when
  incompatible.
- Preserve semantic cards, logical reading/tab order, non-color edge summaries,
  focus visibility, and readable fallback under all failure modes.

## Surfaces

- Reads: semantic graph DOM; BO-009 worker protocol/assets; viewport/font/patch
  lifecycle; BO-008 fixtures.
- Writes: layout hook/adapter, geometry application, SVG layer, fallback,
  layout-health observations, CSS, and tests.
- Contracts: graph DOM data attributes; generation-safe layout lifecycle;
  accessible geometry fallback.

## Sibling boundaries and open gates

BO-012 supplies real graph markup and BO-013/014 own interaction and scale
hardening. Companion shell/CSS work may require merge serialization but does
not define this adapter or become a prerequisite.

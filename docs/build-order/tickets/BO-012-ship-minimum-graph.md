# BO-012 — Ship selectable minimum graph route

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Authenticated LiveView route integrating catalog, graph, layout, and context contracts

**Risk:** high

**Phase hint:** 5

**Depends on:** BO-003, BO-007, BO-010, BO-011

**Serializes with:** none

**Requirements:** BOREQ-001, BOREQ-004, BOREQ-007, BOREQ-009, BOREQ-010, BOREQ-011, BOREQ-012, BOREQ-014

**Decisions:** DEC-002, DEC-003, DEC-007, DEC-008, DEC-009, DEC-010

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d

**Suggested labels:** `complexity:4`, `model:codex`, `phase:5`, `build-lane:frontend`; never `agent:todo`

## Outcome

The dashboard exposes authenticated `/build-orders` catalog and selected-root
routes that render one truthful read-only GitHub planning graph, apply the
layout adapter, open cached ticket context, and preserve explicit valid,
warning, invalid, loading, stale, and unavailable states through URL navigation
and LiveView updates.

## Context and evidence

This is the smallest useful vertical slice. Provider, activity, presenter,
layout, and context contracts are only valuable once an Executor can select a
real root and understand its graph. The prototype's client-only tab state and
sample objects cannot be carried into production.

## Scope

- Add authenticated real routes for the root catalog and selected root. Use a
  stable repository-qualified root locator in server state and a canonical
  issue-number URL for share/back/refresh, validating every parameter.
- Render catalog entries independently so one malformed root has a diagnostic
  and never hides valid siblings. Selecting it renders structural-invalid,
  which is different from catalog unavailable, selected unavailable, stale LKG,
  not found, or a valid empty graph.
- Subscribe/load generation-safely from BO-003 and BO-005/007, showing explicit
  loading, empty, invalid, unavailable, stale, cycle, external-reference, and
  member-warning states without extra provider calls.
- Render server-side lane/phase groups, body-free semantic cards, complete
  accessible titles/status/progress provenance, non-color edge summaries,
  metadata warnings, provider health/freshness, and diagnostics.
- Wire BO-010's DOM/SVG adapter and fallback plus BO-011's selected cached
  context. Keep layout/selection state scoped to canonical root and data
  generation.
- Register the real route through the current route-aware dashboard navigation
  seam, preserving existing Units, Commands/Decisions, Analytics, Basic Auth,
  theme, live/offline, writable/read-only, and back/refresh behavior.
- Keep GitHub planning state read-only: no membership, dependency, label, phase,
  lane, issue-state, or root-state mutation handler. Expose no Aiur runtime
  mutation handler; BO-011 may render only safe links into existing destination
  surfaces.

## Non-goals

- Implement advanced pan/zoom/chain interaction, final responsive/performance
  hardening, dashboard companions, usage cards, or GitHub dependency editing.
- Poll GitHub per LiveView/browser, compute graph policy in JavaScript, fetch a
  body on every card, or clear an edge from Aiur progress.
- Replace current Analytics or other dashboard routes with prototype
  placeholders.

## Existing owner and reuse target

Extend current router, `DashboardLive`/Operator Control Center components,
layouts, route metadata, auth, provider cache/subscription, and CSS ownership.
Consume BO-003/007/010/011 public contracts rather than duplicating them in
assigns or hooks.

## Contract and invariants

- `/build-orders` represents catalog truth; `/build-orders/:root_number`
  represents one selected root. Selection survives share, refresh, reconnect,
  and browser back/forward without mixing graphs.
- Catalog provider failure, per-entry invalidity, selected structural-invalid,
  selected stale/unavailable, and member metadata warnings are distinct
  Executor states.
- Cards and accessible edge/dependency summaries are meaningful before layout
  completes and in fallback. The worker owns geometry only.
- Build Order never mutates GitHub/planning state or invokes an Aiur runtime
  mutation. Destination surfaces remain separately authorized and cannot change
  readiness truth.
- Every visible count/filter/diagnostic derives from the same BO-007 view model.

## Refreshable implementation notes

- Refresh the dashboard route/component topology after current OCC integration
  and any active Executor-name/shell work on the configured integration branch.
- If a companion shell is active, serialize shared route/CSS edits and register
  this route through its accepted seam; never take a hard dependency on
  companion completion.
- Keep provider subscription and route-state helpers outside render functions;
  inject projection owners in tests.

## Acceptance and verification

### Agent gate

- LiveView/router tests cover multiple roots, canonical selection/deep link,
  closed-root link, invalid params, refresh/back/reconnect, auth/read-only, and
  generation-safe updates without extra GitHub calls.
- Catalog tests prove one malformed root leaves valid siblings visible;
  selected structural-invalid differs from stale/unavailable; member warnings
  leave cards renderable.
- BO-008 browser tests cover semantic pre-layout/fallback, real worker layout,
  context open/navigation, all five edge states, cycles/external references,
  existing route regression, and absence of GitHub mutation handlers.

### At-merge gate

- Router/auth/LiveView/provider/component/static/browser tests and full
  repository CI pass on the current configured integration branch after shared
  dashboard seam reconciliation.
- A packaged dashboard can navigate every existing route plus both Build Order
  routes with no client-only tab state or sample prototype data.

### Human/manual evidence

- Reviewer selects valid and invalid roots by URL, refreshes/navigates back,
  opens dependency context, and confirms stale/invalid/warning distinctions and
  safe destination navigation. BO-015 owns final real-root proof.

## Failure, security, migration, and accessibility cases

- Inherit Basic Auth, safe URL, CSRF/write separation, redaction, CSP, and the
  explicit no-mutation boundary; never render raw provider errors.
- Preserve existing route URLs and explicit redirects; no persisted data
  migration is introduced.
- Use semantic headings/navigation/cards/dialog triggers, accessible status and
  dependency summaries, visible focus, and non-color diagnostics before JS.

## Surfaces

- Reads: BO-003 catalog/selected snapshots; BO-007 view model; BO-010 adapter;
  BO-011 context; current route/auth/navigation state.
- Writes: Build Order routes, LiveView/component/navigation integration, CSS,
  subscriptions, and tests.
- Contracts: URL/root selection; route/provider-state matrix; read-only GitHub
  boundary; minimum semantic graph markup.

## Sibling boundaries and open gates

BO-013 owns advanced interaction/accessibility and BO-014 owns redraw/scale.
Shell, Units, Commands, and usage companions are reuse/serialization seams only;
none belongs to this hard dependency graph.

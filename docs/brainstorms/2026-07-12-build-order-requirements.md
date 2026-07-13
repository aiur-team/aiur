---
date: 2026-07-12
topic: build-order-dashboard
---

# Build Order Dashboard Requirements

## Summary

Build Order gives an operator a truthful, selectable dependency view of one
bounded feature while Aiur executes it. GitHub remains authoritative for the
order's identity, member tickets, ticket facts, lifecycle, planning metadata,
and blocker relationships. Aiur contributes current execution activity,
progress, alerts, and event evidence without being allowed to clear a GitHub
dependency.

The net-new Build Order feature is deliberately separate from the refreshed
Units, Commands, and provider-usage dashboard work. The recommended Build Order
implementation is eleven tickets. Eight companion dashboard tickets may ship
independently and do not change Build Order completion, ETA, or ticket count.

## Problem frame

Large Aiur features are planned as dependency graphs, but the operator must
currently reconstruct the plan from a planning PR, GitHub issue bodies, labels,
and live agent state. That breaks down when a repository has multiple epic-level
features, when progress becomes stale, or when prose dependency tables drift
from GitHub's native relationships. A planning document is useful evidence but
must not become a second live tracker.

The view must also resist a known orchestration failure mode: a finite feature
cannot become an endless reliability program merely because capable agents keep
discovering legitimate work. The displayed Build Order and later Executor
handoff therefore pin a finite acceptance boundary and keep deferred findings
outside its completion denominator.

## Actors

- **Operator:** selects a Build Order, understands readiness and execution
  state, opens ticket context, and decides what to dispatch outside this view.
- **Feature Planner:** creates the approved planning baseline and materializes
  its tickets and relationships in GitHub.
- **Executor:** later runs `aiur-run`, protects the finite boundary, and keeps
  critical-path work moving.
- **Aiur worker:** implements one GitHub ticket; it is not a source of planning
  truth.
- **GitHub:** owns materialized plan and lifecycle facts.
- **Aiur runtime:** owns current agent activity and evidence.

## Source precedence

1. Current explicit operator decisions.
2. Captured design evidence for intended behavior.
3. Accepted requirements and technical decisions.
4. GitHub for materialized ticket facts and relationships.
5. Aiur for runtime progress, activity, alerts, and events.
6. Planning documents for approved intent and the baseline graph.

Unknown or stale data remains unknown or stale. It never becomes zero,
unblocked, empty, or successful merely because a provider failed.

## Core workflows

### Select and inspect a Build Order

The operator opens the URL-backed Build Order view, selects one root issue from
the configured repository, and can share or refresh that selection. The page
shows the last complete graph or an explicit loading, empty, unavailable,
stale, invalid, or cyclic state.

### Read the plan and runtime together

Cards are grouped by planned lane and phase. GitHub status and blocker outcome
remain distinct from Aiur execution state and progress. Selecting a card
highlights its upstream and downstream dependency closure and opens reusable
ticket context.

### Continue through degradation

Partial GitHub reads do not publish a partially cleared graph. The last
validated graph stays visible as stale, or the page reports unavailable when no
validated generation exists. Missing runtime activity does not hide a ticket.

### Complete the bounded feature

The feature completes only after the eleven-ticket Build Order is implemented,
reviewed, current-base green, merged, documented, and proven through the named
end-to-end dashboard workflow. Companion dashboard and deferred reliability
work cannot extend that terminal condition.

## Build Order requirements

### Identity and GitHub plan truth

- **BOREQ-001 — Selectable order identity.** Discover multiple Build Order root
  issues in the configured GitHub repository and persist the selected root in
  the URL. Use the GitHub node ID as canonical identity and repository/number as
  the human locator.
- **BOREQ-002 — Explicit membership and metadata.** Direct native sub-issues of
  the selected root are its v1 members, up to 100. Parse exactly one
  `complexity:1..5`, positive `phase:N`, and controlled `build-lane:*` label per
  member; missing/duplicate values render explicit warnings and fallbacks.
- **BOREQ-003 — Native blocker semantics.** GitHub's native `blockedBy`
  relationship is the only hard dependency truth. Render blocker to blocked.
  Only a blocker closed as completed clears an edge; cancelled/not-planned,
  open, unknown, missing, cyclic, or stale blockers do not.
- **BOREQ-004 — Complete provider generations.** Fetch root catalog,
  membership, ticket facts, labels, outcomes, and paginated dependency
  connections in bounded daemon-owned work. Atomically publish only validated
  complete generations and retain last-known-good data with health/freshness.

### Aiur activity and joined read model

- **BOREQ-005 — Shared activity projection.** Project activity for active,
  queued, retrying, paused, and completed member tickets outside the interactive
  TUI. Key it by typed tracker/repository identity and retain source and observed
  time for progress, stage, latest evidence, and waiting reason.
- **BOREQ-006 — Pure state join.** Join GitHub planning truth and Aiur activity
  without fetching, mutating, parsing logs, or defaulting missing fields. Keep
  planned phase, readiness, ticket outcome, execution state, agent stage, and
  progress as separate fields.

### Operator experience

- **BOREQ-007 — URL-backed route and states.** Provide a real LiveView route and
  shared navigation entry with selectable roots, stable back/refresh behavior,
  and explicit loading, empty, unavailable, stale, invalid, and cyclic states.
- **BOREQ-008 — Lane-by-phase graph.** Render controlled horizontal lanes and
  arbitrary positive vertical phase layers, plus Unassigned and Unphased
  fallbacks. Cards show source-backed identifier, title, complexity, lifecycle,
  progress provenance, and an accessible full title even when visually clamped.
- **BOREQ-009 — Honest edges and diagnostics.** Render completed edges as solid
  success, known active blockers as dashed blocking, and unknown/unsatisfied
  outcomes distinctly. Preserve external/missing endpoints and cycle/data
  quality diagnostics instead of dropping them.
- **BOREQ-010 — Complete interaction parity.** Support fit-to-view, bounded
  zoom, pointer pan, wheel/trackpad zoom, keyboard controls, focus/hover/touch
  chain selection, focus visibility, reduced motion, and redraw after relevant
  LiveView/layout changes.
- **BOREQ-011 — Reusable ticket context.** Open ticket detail by mouse,
  keyboard, or touch. Show canonical GitHub navigation, upstream/downstream
  dependency chips, available chat/command actions, partial/error states, and
  correct focus trap, replacement navigation, and focus restoration.
- **BOREQ-012 — Bounded scale.** Keep GitHub calls independent of browser count
  and prove usable rendering/interaction at 20, 50, and 100 members with a
  documented budget. Layout work must not block the browser main thread at the
  maximum fixture.
- **BOREQ-013 — Safe read-only v1.** Build Order performs no tracker mutation.
  It inherits dashboard authentication, privacy, and fail-closed behavior and
  never exposes credentials, raw provider responses, or unsafe external URLs.
- **BOREQ-014 — Durable acceptance.** Ship provider, parser, presenter,
  LiveView, browser, accessibility, degradation, performance, documentation,
  and current-base end-to-end evidence owned by the capstone ticket.

## Separate companion dashboard requirements

These requirements produce separate issues and are not members or blockers of
the Build Order root.

- **DREQ-001 — Shared responsive shell.** Replace client-only page tabs with
  URL-backed Units, Commands, Build Order, and existing Analytics navigation.
  Preserve real analytics, live/read-only/operational meaning, theme access,
  `aria-current`, and full reachability at 320, 390, 768, and 960 pixels.
- **DREQ-002 — Units read model and filters.** Present one truthful Units
  catalog with explicit status precedence or orthogonal predicates, named
  scope presets, independent status filters, exact counts, URL persistence,
  zero-result recovery, reduced-motion-safe updates, and preserved waiting
  reasons.
- **DREQ-003 — Unit and capacity controls.** Reuse the authoritative control
  plane for authenticated per-unit pause/resume and max-agent changes with
  capability gating, idempotent pending state, authoritative confirmation,
  concurrency/error recovery, auditability, and accessible names. Never flip
  row or capacity state locally as proof.
- **DREQ-004 — Commands catch-up.** Apply the refreshed Commands vocabulary and
  primary filters while preserving every durable Decision lifecycle state,
  deep links, blocking context, confirmation, sanitization, retry, revisions,
  follow-ups, and bounded-history partial-result semantics.
- **DREQ-005 — Durable usage observations.** Persist idempotent token and raw
  provider-reported cost observations by run, ticket, attempt, backend, agent
  family, and resolved model across retries, fallback, completion, and restart.
- **DREQ-006 — Cost and aggregation projection.** Compute exact basis-labelled
  cost and coverage plus totals by build/run, ticket, agent family, backend, and
  model from durable observations with versioned pricing and explicit unknowns.
- **DREQ-007 — Provider account meters.** Normalize subscription and API-key
  account/quota windows for Codex and Claude, preserve sparse multi-limit
  updates, and expose supported, partial, stale, error, and unsupported states
  without scraping credentials or interactive output.
- **DREQ-008 — Shared usage summary.** Render Units-only provider and Aiur
  summary cards with tokens, spend, ticket/run/build scope, progress/ETA
  provenance, cost basis/coverage, observed time, accessible meters, responsive
  DOM/visual order, and truthful empty/degraded states.

## Acceptance examples

1. Two open root issues have `build-order`; selecting the second updates the
   URL, survives refresh, and never mixes members from the first.
2. A blocker reports Aiur progress `100%` but remains open in GitHub; its edge
   stays blocking and its dependent is not ready.
3. A blocker closes with `NOT_PLANNED`; its edge becomes terminal-unsatisfied,
   not cleared.
4. Page two of a dependency connection fails; the prior complete graph remains
   visible as stale and no disappeared edge makes a ticket look ready.
5. Aiur restarts without replayed progress; open ticket progress is unknown,
   while GitHub title, phase, lane, lifecycle, and dependencies remain visible.
6. A keyboard user selects a card, traverses dependency chips in ticket
   context, closes the dialog, and focus returns to the originating card.
7. At 390px, every navigation item, summary fact, filter, and unit action is
   reachable without page-level horizontal clipping; only the graph viewport
   may intentionally pan in two dimensions.
8. The 100-ticket fixture lays out off the main thread, remains interactive,
   and reports external references and cycles rather than silently dropping
   them.

## Non-goals

- Editing membership, planning labels, phase/lane, or dependencies in v1.
- Linear or cross-repository Build Orders in v1.
- Nested visualization, more than 100 direct members, or multi-order ticket
  membership.
- Making phase a global execution barrier.
- Treating Aiur progress as dependency completion.
- Reproducing the prototype's client-only data, fake controls, hard-coded URLs,
  analytics placeholder, or pixel density without accessibility proof.
- Including Units, Commands, usage/accounting, or deferred reliability work in
  Build Order completion.

## Open product gates

The durable question list lives in `docs/build-order/questions.md`. Until the
operator answers, the planning baseline assumes same-configured-repository and
read-only v1, preserves explicit incomplete Claude Remote Control accounting,
and keeps cost/build-window choices inside the companion usage tickets.

## Evidence

- `docs/build-order/design-manifest.md`
- `docs/build-order/prototype/feature-constraints.md`
- `docs/build-order/00-research-spike.md`
- `docs/build-order/01-decomposition-patterns.md`
- `docs/build-order/02-dashboard-design-delta.md`
- `docs/build-order/03-source-of-truth-and-state.md`
- `docs/build-order/04-usage-accounting.md`
- GitHub GraphQL schema introspection at research time confirmed `Issue.parent`,
  `subIssues`, `blockedBy`, and `blocking`, plus add/remove relationship
  mutations.
- GitHub documents a maximum of 100 direct sub-issues per parent.
- Eclipse ELK/elkjs documents layered directed layout, routed edges, browser
  Web Workers, and layout-only integration suitable for accessible DOM cards.

# BO: BO-020 — Render plan phase and epic breakdowns

**Kind:** executable

**Provenance:** planned in plan v1 after operator design review (2026-07-13)

**Complexity:** 2 — bounded presentation over the already-validated graph snapshot

**Risk:** low

**Phase hint:** 6

**Depends on:** BO-003, BO-012

**Serializes with:** BO-013, BO-014 — shared Build Order route component and CSS

**Requirements:** BOREQ-016

**Decisions:** DEC-005, DEC-010

**Design evidence:** DESIGN-002; operator direction 2026-07-13 (plan-preview review)

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:2`, `model:codex-gpt-5.6-terra`, `phase:6`, `build-lane:dashboard-ui`; never `agent:todo`

## Outcome

Executors see, on the Build Order page itself, how the selected plan
distributes across phases and epics — ticket counts and complexity-point
totals with point-weighted bars — plus complexity-weighted live completion for
each populated rollout phase, so heavier phases and lanes are visible at a
glance and expectations about which phases take longer are grounded in the
plan's own weights and authoritative runtime progress.

## Context and evidence

The operator reviewed the plan-preview rendering of this pack and directed
that its tickets-per-phase and tickets-per-epic breakdowns become part of the
real Build Order page, not a one-off visualization. No existing ticket owns
plan-summary presentation: BO-012 ships the minimum graph, BO-013 owns graph
interaction/accessibility hardening, BO-014 owns scale proofs, and the
companion run/usage summaries (DASH-022/DASH-031) cover a different data
domain entirely. The refreshed committed OCC mock adds a Build Order summary
strip with complexity-weighted phase progress; this ticket owns that later-phase
presentation together with the existing phase/epic breakdowns.

## Scope

- Render a per-phase breakdown for the selected Build Order: for each
  populated phase, member count, complexity-point total, a point-weighted
  bar, and the member IDs. Render a per-epic (lane) breakdown with the same
  facts. Both derive from the same validated BO-003 graph generation the
  graph renders — no separate provider fetch and no second projection.
- Render a compact plan KPI strip: total members and points, ready-at-start
  count (members with no unsatisfied blockers), and longest dependency-chain
  length.
- Render one progress segment for each populated rollout phase. Segment width
  is weighted by that phase's total complexity points, and completion is
  `sum(member complexity * authoritative progress) / sum(member complexity)`.
  Show the numeric percentage and completed/total point context; use the
  refreshed mock's red-to-green hue only as decorative reinforcement.
- Update reactively when the graph generation or BO-007 joined runtime snapshot
  changes. Unknown, stale, or degraded planning/runtime inputs show the same
  named unknown/stale/unavailable state as the graph and ticket activity —
  never zero completion or an empty healthy table.
- Use accessible table semantics (real tables with headers and captions);
  bars are decorative reinforcement with the numeric values always present
  as text. Present phase as a rollout hint (DEC-010) — the breakdown must
  not imply phase gating or readiness.
- Place the breakdowns below or beside the graph without stealing keyboard
  focus from graph controls; a collapsed/summarized presentation on narrow
  viewports is acceptable if the full tables remain reachable.

## Non-goals

- Usage, token, or cost data (companion accounting tickets own that domain).
- Analytics navigation, assets, or data; Analytics is intentionally excluded
  from this program.
- Editing, filtering, or re-grouping controls beyond expand/collapse.
- Per-ticket detail or navigation (BO-016/BO-018/BO-011 own ticket context).
- Changing graph layout, interaction, or scale budgets (BO-010/013/014).

## Existing owner and reuse target

Extend the Build Order LiveView route component BO-012 establishes, reading
the same snapshot assigns. Copy the summary table/card markup patterns from
the Executor Control Center components rather than inventing a new table
style.

## Contract and invariants

- The breakdowns are projections of the same validated BO-003 generation the
  graph renders; they never fetch independently and never disagree with the
  graph about membership, phase, lane, or counts.
- Point totals sum the members' single complexity values; a member with
  missing/duplicate metadata appears in an explicit warning bucket and is
  excluded from totals rather than guessed.
- Phase progress consumes BO-007's joined authoritative progress and preserves
  its freshness/unknown semantics. Missing progress is not coerced to zero,
  and a terminal completion is never inferred from a percentage.
- Phase remains a rollout hint (DEC-010); nothing in the breakdown implies
  phase-based readiness or gating.
- Unknown/stale/degraded generations present the named stale/unavailable
  state — never zeros, never an empty healthy table.

## Refreshable implementation notes

- Group members with `Enum.group_by/2` over the BO-003 snapshot's normalized
  members by phase and by lane; point totals fold the BO-001 complexity
  records. Ready-at-start and longest-chain facts should come from the BO-007
  readiness/graph module rather than a re-derivation in the view.
- The committed plan preview (`docs/build-order/plan-preview.html` — open it
  in a browser; it renders this pack's real data) demonstrates
  the intended layout: two side-by-side tables — Phase | count | points |
  bar | tickets and Epic | count | points | tickets — plus a KPI strip.
- The refreshed prototype
  (`docs/build-order/prototype/Aiur Operator Control Center.html`) is the visual
  reference for the summary strip: inspect `.bo-prog`, `.bo-prog-seg`, and
  `renderBoSummary`. Preserve the weighted-width and weighted-completion
  semantics, but implement them from trusted BO-007 data rather than copying
  prototype fixture logic. Production segments represent rollout
  `phase_hint`, not a readiness gate.
- CSS lives with the Build Order route styles; note `dashboard.css` is
  embedded at compile time via `@external_resource`, so CSS edits require a
  recompile to observe.

## Acceptance and verification

### Agent gate

- Component tests cover 0/1/N-member snapshots, phases and lanes with
  missing/duplicate metadata (rendered as an explicit warning bucket, never
  a crash or silent drop), point totals, ready-at-start counts, and the
  degraded-generation stale state.
- Presenter/component tests prove weighted segment widths and
  `sum(complexity * progress) / sum(complexity)` completion, including mixed
  complexity, 0/100 boundaries, unknown/stale progress, and terminal outcomes
  that disagree with a stale percentage.
- Browser tests cover desktop and 390 px presentation, table semantics under
  a screen reader, named progress values that do not rely on color, and that
  graph keyboard interaction is unaffected.

### At-merge gate

- Build Order page, component, browser, accessibility, and full repository
  CI gates pass on the current configured integration branch with BO-012's
  graph behavior unchanged.

### Human/manual evidence

- None separately; BO-015 exercises the published root's page including this
  region.

## Failure, security, migration, and accessibility cases

- Degraded or unavailable snapshots keep the named stale/unavailable state;
  the breakdown never presents an empty plan as healthy.
- Unknown/stale runtime progress stays visibly unknown/stale and is never
  rendered as `0%`; hue and bar length are never the only status encoding.
- No new data sources, persistence, or migration; renders only normalized
  planning facts already on the page.
- Tables use semantic markup with textual values; color/bars are never the
  only encoding.

## Surfaces

- Reads: BO-003 validated graph snapshot; BO-007 joined readiness and runtime
  progress facts.
- Writes: Build Order page summary component, route CSS, component and
  browser tests.
- Contracts: plan phase/epic breakdown and complexity-weighted phase-progress
  presentation.

## Sibling boundaries and open gates

BO-013 owns graph interaction and accessibility hardening; this ticket owns
only the summary region and must not modify graph controls. BO-014's scale
budgets apply to the whole route — the breakdown must not regress them.
DASH-022 owns the nonfinancial run summary and DASH-031 owns protected
usage/cost; neither overlaps this planning-facts region.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-020`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

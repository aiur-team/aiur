# DASH-002 — Align Units read model and filters

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — All-state catalog, status policy, URL filters, and responsive table

**Risk:** high

**Depends on:** none

**Requirements:** DREQ-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Units presents one truthful catalog with backend/model/effort/complexity/progress and exact Live/Unfinished/All/None plus Active/Alert/Paused/Stuck/Queued/Finished filter semantics.

## Context and evidence

Current production separates running, queued/waiting, and retry tables. The prototype's one-bucket priority misclassifies some blocked units and hides waiting reasons. The refreshed visual is useful only after the product defines canonical predicates, counts, presets, persistence, and unknown/completed sources.

## Scope

- Define an all-state Units row contract and explicit orthogonal predicates or reviewed precedence for lifecycle, alert, pause, stuck, queue, blocked/waiting, and finished signals.
- Add real backend, model, effort, complexity, progress provenance/staleness, latest evidence, duration, decisions, and safe actions with honest unknowns.
- Implement named presets, independent status chips, exact counts, URL/share/back persistence, zero-result reset, and accessible selection/announcements.
- Render one responsive table/card presentation without losing waiting reason or provider-health diagnostics; consume shared TicketActivity if available rather than creating a second fold.
- Integrate the shared ticket-context surface when available, with a small compatibility adapter otherwise.

## Non-goals

- Implement mutation controls, usage/accounting, Commands, Build Order graph, or fake finished/progress rows.
- Copy the prototype's flawed bucket precedence or client-mutated sample data.

## Existing owner and reuse target

Extend `AiurWeb.Presenter`, current fleet/Units components, Orchestrator snapshot/status projections, and RecentMerge/TicketActivity owners. Reuse BO-004/006 contracts when landed; do not duplicate them.

## Contract and invariants

- Row membership and each filter predicate are independently testable; counts use the same canonical predicates as visible rows.
- Unknown progress/provider data never becomes zero or Active.
- URL params are canonical, validated, back/refresh stable, and recoverable from an empty result.
- Animation is optional polish, never affects ordering/focus, and follows live reduced-motion preference.

## Refreshable implementation notes

- Refresh current completed-ticket and TicketActivity availability at pickup; record any external dependency rather than duplicating a store.
- Keep filter policy pure and view rendering separate.

## Acceptance and verification

### Agent gate

- Policy tests cover every multi-signal combination including alert+paused, stuck+blocked, waiting, finished, unknown, and conflicting labels.
- LiveView/browser tests cover presets/chips/counts/URL/back, zero result, provider degradation, responsive rows, focus, announcements, and reduced motion.

### At-merge gate

- Current-base dashboard/presenter/status and full CI pass after shared-component reconciliation.

### Human/manual evidence

- Reviewer verifies multi-signal rows and filters at desktop and 390px without losing waiting context.

## Failure, security, migration, and accessibility cases

- No raw workspace/provider/credential data in rows or URLs.
- Preserve current fleet API compatibility or version it explicitly.
- All filters/rows/actions are named, keyboard/touch reachable, and non-color-dependent.

## Surfaces

- Reads: Orchestrator/TicketActivity/RecentMerge snapshots; Decision counts; route params.
- Writes: Units read model/filter policy/components/tests.
- Contracts: UnitsRow and canonical filter truth table.

## Sibling boundaries and open gates

DASH-003 owns writes. DASH-008 owns summary cards. BO-008 owns shared ticket context. Coordinate `DashboardLive` and CSS changes with DASH-001/004.


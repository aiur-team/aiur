# Dashboard and Prototype Delta

**Current-code baseline:** `origin/main` at
`e5f07d02644aba9e22953e644791b055d3279678`  
**Design baseline:** [design-manifest.md](design-manifest.md)

The prototype combines four scopes: a richer shared shell/read model, a
substantial Fleet-to-Units redesign, a smaller Decision-to-Commands alignment,
and the net-new Build Order graph. It is not a CSS-only restyle.

## Current production baseline

The merged Operator Control Center already has:

- Phoenix LiveView routes for Fleet, Decision inbox/detail, and analytics;
- independently degrading fleet, decision, history, recent-merge, outcome, and
  analytics providers;
- URL-persisted decision filters and deep links;
- durable decision lifecycle, retries, revisions, confirmation, follow-up, and
  fail-closed writable behavior;
- a responsive current fleet table and accessible theme/reduced-motion tokens;
- GitHub native dependency read/write clients and Aiur progress events.

It does not have a Build Order route, an all-state ticket catalog, a shared
runtime progress projection, a general ticket-detail component, provider-split
accounting/rate limits, or a maintained graph-layout integration.

## Catch-up ticket A: shared shell and Units

This should be one bounded ticket unless detailed planning exposes separate
provider-accounting scope.

| Area | Current | Target and constraint |
|---|---|---|
| Navigation | Fleet and Decision inbox route links | Full-width Units, Commands, Build Order navigation while preserving URL/back behavior. Build Order route itself remains net-new work. |
| Top shell | Live/offline, tracker, agent kind, UTC, theme | Live, analytics, theme, and truthful optional ETA/provider summaries. Do not show invented values. |
| Usage/rate limits | Aggregate tokens and one latest provider-unattributed rate-limit map | Provider-keyed, observed-at data is required before per-provider cards can be canonical. |
| Spend | No price/version source | Defer, or show an explicitly configured/versioned estimate. Never copy mock constants. |
| Units data | Ticket/state/waiting/latest/elapsed/decisions/actions | Add real backend/model/effort/complexity/progress/epic-lane data with honest unknowns. Preserve waiting reason. |
| Filters | Independent Active/Blocked/Paused/Stuck/Finished/Total | Define the exact grouped Live/All toggle truth table; do not copy the mock's surprising “any child selected means clear all” behavior. |
| Max agents | No dashboard control; runtime controls exist | Use real max/active/draining state, writable gate, and errors. Never mutate rows to fake a pause. |
| Row detail | Only running rows open an agent-log modal | A reusable ticket-context component with safe GitHub/chat/command links and honest unavailable states. |
| Mobile | Labelled fleet cards | Preserve accessible labels and readable text; the mock's 9–12px density is not acceptance. |

Build Order must not depend on all shell metrics landing. The shared route/tab
contract and ticket-context component are the only likely cross-scope seams.

## Catch-up ticket B: Commands

Keep the Decision domain and persistence names. “Commands” is operator-facing
vocabulary and composition, not a storage migration.

- Rename the tab/banner/card copy to Commands and “unit needs command.”
- Reorder and relabel canonical filters: Open, Blocking, Answered not delivered,
  Decided by supervising agent, Resolved, Superseded, All.
- Preserve URL filter state and stable decision detail routes.
- Add provider/model origin, option previews, supervising/selected-answer chips,
  and recommendation confidence only when canonical fields exist.
- Preserve irreversible confirmation, sanitization, retry, writable gating,
  revisions, and follow-ups.
- Do not copy prototype-only quick choice, Defer, or Acknowledge behavior unless
  a real command contract is separately accepted.

This catch-up is independent of the Build Order data provider and graph.

## Build Order behavior inventory

### Route and selection

- third URL-backed dashboard view;
- selector for multiple active Build Order root issues;
- selected order survives refresh/share/back navigation;
- explicit loading, empty, unavailable, stale, invalid, and cyclic states;
- zoom/pan/selected-node state may remain browser-local and keyed by root.

### Layout and cards

- horizontal controlled lanes: Documentation, Frontend, Backend,
  Infrastructure, plus an Unassigned fallback;
- vertical arbitrary positive planned phases plus Unphased fallback;
- phase is a preferred layout layer, not a gate;
- cards show source-backed ID/title/status/progress/complexity/lane only;
- unknown or stale progress is indeterminate/labelled, never `0%`;
- deterministic icons from lane/status in v1;
- shared ticket context opens on click, focus+Enter/Space, or touch selection.

### Edges and graph diagnostics

- direction is blocker to blocked;
- green/solid only for a successfully completed GitHub blocker;
- red/dashed for a known open blocker;
- an explicit distinct state for unknown data and a cancelled/not-planned
  blocker whose edge remains unsatisfied;
- missing/external blockers remain visible as diagnostics/counts;
- cycles render with a graph-quality warning and never invent readiness;
- hover, keyboard focus, and persistent touch selection highlight upstream and
  downstream closure.

### Canvas interaction

- maintained layout/routing ownership rather than the mock's fixed SVG sketch;
- fit-to-view, bounded zoom, pointer pan, wheel/trackpad zoom, and accessible
  keyboard controls;
- redraw after LiveView patches, font readiness, resize, theme changes, and
  card-content changes;
- preserve focus visibility and reduced-motion behavior;
- narrow screens may use an internal two-dimensional viewport if controls,
  focus visibility, and touch behavior are proven.

## Prototype behavior that is not a requirement

- illustrative sample counts, statuses, token totals, dollar spend, ETA, and
  max-agent mutations;
- clearing dependencies from Aiur `100%` progress;
- client-only tabs, filters, ticket/command data, or fake row state;
- phases restricted to 1–5;
- all nodes visible on one screen;
- mouse-only clickable `div`s;
- silent edge deletion when endpoints are missing;
- the deterministic build-less layout as production architecture.

## Minimum acceptance matrix

- parser/graph tests: duplicate or missing metadata, arbitrary phases, external
  dependencies, cycles, terminal classification, unknown data;
- provider tests: open and closed members, 100 children, pagination, partial
  errors, rate limits, last-known-good cache, bounded calls independent of
  browser count;
- runtime tests: typed identity join, progress provenance/staleness, restart
  unknowns, planned phase distinct from active CE stage;
- LiveView tests: routes/selector/deep links, degraded providers, ticket context,
  read-only behavior;
- browser tests: focus/hover/touch chain selection, modal focus return,
  pan/zoom/fit bounds, live redraw, light/dark/reduced motion, narrow viewport;
- performance fixtures: 20, 50, and 100 tickets with cross-lane edges and a
  documented render/interaction budget.

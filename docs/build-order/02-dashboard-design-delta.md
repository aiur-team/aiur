# Dashboard and Prototype Delta

**Current-code baseline:** `origin/main` at
`3d67b7be722eb649f28088fc8d609dd7b75254c7`

**Design baseline:** [design-manifest.md](design-manifest.md)

The prototype combines four scopes: a richer shared shell/read model, a
substantial Fleet-to-Units redesign, a smaller Decision-to-Commands alignment,
and the net-new Build Order graph. It is not a CSS-only restyle.

The companion dashboard work is separate from Build Order: responsive shell,
Units read model, unit/capacity controls, Commands, and the four-ticket
usage/accounting track in `04-usage-accounting.md`. None of those tickets enters
the Build Order root or feature-completion calculation.

## Current production baseline

The merged Operator Control Center already has:

- Phoenix LiveView routes for Fleet, Decision inbox/detail, and analytics;
- independently degrading fleet, decision, history, recent-merge, outcome, and
  analytics providers;
- URL-persisted decision filters and deep links;
- durable decision lifecycle, retries, revisions, confirmation, follow-up, and
  fail-closed writable behavior;
- a decision overview intentionally bounded to the most recent 50 canonical
  records, with unresolved/blocking/urgent items ordered ahead of recency;
- Basic Auth required whenever the dashboard enables mutations, including on
  loopback; an unconfigured writable dashboard fails closed at startup;
- a responsive current fleet table and accessible theme/reduced-motion tokens;
- GitHub native dependency read/write clients and Aiur progress events.

It does not have a Build Order route, an all-state ticket catalog, a shared
runtime progress projection, a general ticket-detail component, provider-split
accounting/rate limits, or a maintained graph-layout integration.

## Catch-up ticket A: responsive shell

This ticket owns URL-backed navigation, per-view headers, shared responsive
layout, and preservation of existing Analytics. It does not own Units data,
controls, usage cards, Commands composition, or the Build Order page.

| Area | Current | Target and constraint |
|---|---|---|
| Navigation | One LiveView route composed from Fleet and Decision sections | Responsive sidebar/bottom navigation for Units, Commands, Build Order, and the existing authenticated Analytics route while preserving URL/back behavior. Build Order route itself remains net-new work. |
| Page identity | One Operations Dashboard hero | Per-view icon/title plus truthful status. Do not duplicate route state in client-only tabs. |
| Top shell | Live/offline, tracker, agent kind, UTC, theme | Live, theme, and truthful optional ETA/provider summaries. Do not show invented values. |

The production shell must preserve real analytics and operational metadata that
the mock removes. At 320, 390, 768, and 960 pixels, every navigation item and
theme/status affordance remains reachable without page-level clipping.

## Catch-up ticket B: Units read model and filters

| Area | Current | Target and constraint |
|---|---|---|
| Units data | Ticket/state/waiting/latest/elapsed/decisions/actions | Add real backend/model/effort/complexity/progress/epic-lane data with honest unknowns. Preserve waiting reason. |
| Filters | Separate Running, queued/waiting, and retry tables | One Units table with single-select Live/Unfinished/All/None presets plus independently toggleable Active/Alert/Paused/Stuck/Queued/Finished chips; define exact precedence for rows matching multiple signals. |
| Row detail | Only running rows open an agent-log modal | A reusable ticket-context component with safe GitHub/chat/command links, navigable blocker/blocked-ticket chips, and honest unavailable states. |
| Mobile | Labelled fleet cards | Preserve accessible labels and readable text; the mock's 9–12px density is not acceptance. |

Rows matching multiple signals need an accepted truth table; the mock's
Finished > Alert > Paused > Stuck > Queued > Active bucket order misclassifies
some blocked units. Filter counts, selected state, zero-result reset, URL
persistence, focus, announcements, and reduced-motion behavior are part of the
contract rather than polish.

## Catch-up ticket C: unit and capacity controls

- Reuse the current `AgentChat`/control-plane capabilities for per-unit
  pause/resume and the runtime max-agent control for capacity changes.
- Define eligible states, read-only/auth gating, pending/idempotency,
  authoritative PubSub confirmation, double-click/concurrent-state handling,
  timeouts/errors, and worker-slot/capacity failures.
- Preserve pause and waiting reasons; never mutate a row or cap locally and
  present that as success.
- Provide explicit accessible names, state, focus, and unavailable reasons.

Build Order must not depend on shell metrics or writable controls landing. The
shared route contract and ticket-context component are the only likely
cross-scope seams.

## Catch-up ticket D: Commands

Keep the Decision domain and persistence names. “Commands” is operator-facing
vocabulary and composition, not a storage migration.

- Rename the tab/banner/card copy to Commands and “unit needs command.”
- Reorder and relabel canonical filters: Open, Blocking, Answered not delivered,
  Decided by supervising agent, Resolved, Superseded, All.
- The refreshed mock simplifies visible filters to Open, Blocking, Resolved,
  and All. Keep other canonical states reachable by detail/history or an
  explicitly accepted product decision; do not silently hide actionable work.
- Preserve URL filter state and stable decision detail routes.
- Add provider/model origin, option previews, supervising/selected-answer chips,
  and recommendation confidence only when canonical fields exist.
- Use the refreshed “Issue commands” banner wording only when the count and
  blocking semantics come from the bounded canonical projection. Because that
  projection retains 50 records, deep links and counts outside the window need
  on-demand lookup or an explicit partial-results state.
- Preserve irreversible confirmation, sanitization, retry, writable gating,
  revisions, and follow-ups.
- Do not copy prototype-only quick choice, Defer, or Acknowledge behavior unless
  a real command contract is separately accepted.

This catch-up is independent of the Build Order data provider and graph.

## Companion usage/accounting track

The shell cards require four independently reviewable outcomes:

1. durable idempotent usage observations attributed by ticket, run, backend,
   agent family, and exact model;
2. cost/coverage and grouping projections over those observations;
3. provider account-meter ingestion for subscription and API-key modes; and
4. shared OCC summary cards with honest scope, cost basis, coverage, staleness,
   and unavailable states.

See `04-usage-accounting.md` for boundaries and evidence. Build Order may pass
its selected member IDs to the accounting query, but its own data provider,
graph, interactions, and acceptance do not depend on provider billing.

## Build Order behavior inventory

### Route and selection

- third URL-backed dashboard view;
- responsive shared navigation can land independently; the Build Order ticket
  must consume the accepted route contract rather than reimplement the shell;
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
- ticket context includes safe GitHub navigation and navigable upstream and
  downstream dependency chips without turning the dashboard into an editor.

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

# BO-009 — Ship selectable minimum graph

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — URL-backed LiveView page integrating four new contracts

**Risk:** high

**Phase hint:** 5

**Depends on:** BO-003, BO-006, BO-007, BO-008

**Serializes with:** none

**Requirements:** BOREQ-001, BOREQ-007, BOREQ-008, BOREQ-009, BOREQ-011, BOREQ-013

**Decisions:** DEC-002, DEC-003, DEC-007, DEC-008, DEC-009, DEC-010

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`, `phase:5`, `build-lane:frontend`; never `agent:todo`

## Outcome

The authenticated dashboard exposes `/build-orders` and `/build-orders/:root_number`, selects one GitHub-rooted order, and renders a truthful read-only lane-by-phase graph with provider states, cards, edges, diagnostics, and reusable ticket context.

## Context and evidence

This is the smallest useful end-to-end slice: provider snapshots and activity join become an actual operator route, without hiding fetching or graph policy inside LiveView.

The refreshed prototype moves navigation into a responsive shell, but production already has real Analytics and URL-backed Decision routes. This ticket consumes the current shared route contract and must not recreate client-only tabs or regress existing routes.

## Scope

- Add authenticated read-only routes for the catalog and selected root. Canonicalize a deterministic catalog selection to `/build-orders/:root_number`; direct lookup keeps a closed selected root deep link usable.
- Subscribe to graph/activity PubSub, load injected snapshots, and render loading, empty catalog, unavailable, stale LKG, invalid root/metadata, cyclic, and not-found states.
- Render server-side lane/phase headers, accessible cards, full-title affordances, complexity pill, lifecycle/progress/status, directed edge semantics, external/missing diagnostics, and provider freshness.
- Wire the BO-007 layout hook/worker and BO-008 ticket context without adding provider I/O or mutation.
- Add/update the shared navigation entry and page metadata using real links, `aria-current`, back/refresh semantics, and preservation of the existing Analytics capability.
- Keep zoom/selected-card browser state keyed by canonical root when possible, but leave advanced interaction/scale hardening to BO-010.

## Non-goals

- Edit membership, labels, phases, lanes, or dependencies; expose a write control; or add Linear/cross-repository support.
- Implement usage cards, Units filters/controls, Commands catch-up, Analytics redesign, or final graph polish.
- Poll GitHub per LiveView, compute graph policy in JavaScript, or clear edges from Aiur progress.

## Existing owner and reuse target

Extend `AiurWeb.Router`, `AiurWeb.DashboardLive` or current extracted dashboard components, `AiurWeb.Layouts`, and dashboard CSS using the BO-003/006/007/008 public contracts. Preserve Basic Auth and writable fail-closed behavior from `AiurWeb.Router`/`HttpServer`.

## Contract and invariants

- `/build-orders` resolves only catalog truth; selected graph state lives at `/build-orders/:root_number` so share/back/refresh are deterministic.
- Internal cache/join keys remain canonical node IDs even though the external URL uses the issue number.
- Every provider/dependency uncertainty is visible; no error path renders an empty ready graph.
- Node cards and dialog triggers are semantic controls before JavaScript layout runs.
- Build Order has no mutation event handlers in v1 and remains available under the dashboard's authenticated read-only mode.

## Refreshable implementation notes

- Refresh the dashboard route/component topology at pickup because active dashboard PRs may extract the current monolithic LiveView.
- Land/rebase the shared shell first when it is already approved; otherwise add only the minimal real Build Order link and avoid duplicating the whole prototype shell.
- Keep state-transition helpers outside render functions and test routes with injected projection processes.

## Acceptance and verification

### Agent gate

- LiveView tests cover catalog default/canonical URL, multiple roots, closed-root deep link, refresh/back-compatible params, every provider state, cycles/external blockers, read-only auth, and ticket-context wiring.
- Rendered tests assert full accessible card/title/status/edge diagnostics and prove no fake data from the prototype appears.
- Integration tests prove PubSub updates replace assigns without extra GitHub calls and stale/partial providers remain explicit.

### At-merge gate

- Router/auth/LiveView/component/static-asset suites and current-base full CI pass after dashboard branch reconciliation.
- At-merge smoke uses a synthetic 20-ticket graph and confirms existing Units, Commands/Decisions, Analytics, and API routes still work.

### Human/manual evidence

- Reviewer opens multiple Build Orders by URL, navigates a dependency chip, refreshes, and confirms current selection/context and provider warnings remain understandable.

## Failure, security, migration, and accessibility cases

- Security: inherit dashboard Basic Auth, safe link policy, CSRF/write separation, and no raw provider/error payload rendering.
- Migration: preserve existing `/`, `/decisions`, `/decisions/:id`, `/analytics`, and API compatibility or add explicit tested redirects.
- Accessibility: semantic DOM works before hook completion; route/page headings, cards, edge summaries, provider warnings, and modal triggers are labelled.

## Surfaces

- Reads: root catalog and selected graph projections; BuildOrderViewModel; layout adapter; TicketContext.
- Writes: Build Order routes/page/components/navigation/CSS; LiveView integration tests.
- Contracts: URL selection/deep-link behavior; minimum graph page states; read-only navigation integration.

## Sibling boundaries and open gates

BO-010 owns interaction/scale hardening. Companion shell may own final shared layout; consume current main rather than forking it. Usage, Units controls, and Commands do not block this route.


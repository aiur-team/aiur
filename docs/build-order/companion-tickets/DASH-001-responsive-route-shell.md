# DASH-001 — Ship responsive route-aware shell

**Kind:** executable

**Provenance:** planned in plan v1 after refreshed-prototype and current-main review

**Complexity:** 3 — Shared route metadata and responsive navigation across unlike route types

**Risk:** medium

**Phase hint:** 2

**Depends on:** BO-008

**Serializes with:** BO-012 — shared OCC route/navigation shell

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-001

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex`, `phase:2`, `build-lane:dashboard-ui`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

The Executor Control Center has URL-backed desktop and mobile navigation with a truthful per-route header for Units, Commands, the registered Build Order route, and the existing Analytics document, without clipping or client-only tab state.

## Context and evidence

Current main exposes LiveView routes at `/`, `/decisions`, and
`/decisions/:decision_id`, plus a controller-backed secure Analytics document
at `/analytics`. The refreshed prototype demonstrates a desktop sidebar and
mobile bottom navigation but treats Analytics as a fake client panel and clips
navigation at narrow widths. GitHub #1034 completed the user-facing
Operator-to-Executor rename on current main; this ticket consumes that landed
terminology and the resolved integration baseline rather than reopening it.
BO-008 first establishes the shared authenticated Phoenix/LiveView browser,
accessibility, responsive-screenshot, and artifact harness so this shell and
all of its downstream companions prove real-route behavior with one test
platform rather than inventing a second browser runner.

## Scope

- Define one declarative route registry containing route identity, label, icon, route type, availability, and active-match policy. It must support LiveView navigation and ordinary document links without pretending `/analytics` is a LiveView patch.
- Extract shared shell, navigation, and per-view header components from the current dashboard while preserving the existing route URLs, direct Decision links, back/forward behavior, theme control, live/offline truth, tracker and agent-kind metadata, and read-only/writable status.
- Render a sticky desktop sidebar at wide widths and a bottom navigation at narrow widths. Account for browser safe-area insets and reserve enough content padding that the bottom navigation never obscures facts or actions.
- Provide a stable registration seam for the Build Order route. An unregistered future route is omitted or visibly unavailable; it is never an active broken link.
- Preserve the real Analytics route and authentication behavior. The shell may summarize availability, but it must not replace Analytics with placeholder content.

## Non-goals

- Implement Build Order content, Units rows or filters, Commands composition, usage cards, unit controls, or Analytics redesign.
- Rename durable Decision or OCC implementation identifiers merely to match user-facing Executor terminology.
- Copy the prototype's client-side tab buttons, hard-coded counts, visual DOM reordering, or fake Analytics page.

## Existing owner and reuse target

Extend `AiurWeb.DashboardLive`, `AiurWeb.Layouts`, `AiurWeb.Router`, the current dashboard asset pipeline, and `TelemetryDashboardController`. Reuse the authentication and writable/read-only contracts established on the resolved configured integration target.
Reuse BO-008's Phoenix/LiveView browser helpers, viewport/theme/reduced-motion
controls, authentication fixtures, accessibility engine, and sanitized failure
artifacts; this ticket may add shell scenarios but must not fork the harness.

## Contract and invariants

- The URL and current route/action are the only source of selected navigation state; browser-local tab state is not authoritative.
- Every registered destination has one accessible name, one active-match policy, and an appropriate navigation primitive for its route type.
- DOM order equals visual and screen-reader order. Navigation, theme, status, and view content remain reachable at 320, 390, 768, and 960 CSS pixels and at 200% text zoom.
- No shell component invents provider, ETA, spend, progress, live, or authentication values.
- Existing Basic Auth, supervisor authentication, CSRF, secure-document, and writable gates remain unchanged unless a later ticket explicitly strengthens the financial-data boundary.

## Refreshable implementation notes

- Refresh current dashboard PRs at pickup and confirm the resolved integration
  target contains #1034's accepted Executor terminology before editing shared
  copy.
- Likely extract HEEx components and route metadata rather than expanding the already-large `DashboardLive.render/1`.
- Use CSS logical properties and `env(safe-area-inset-bottom)` where supported. Test long localized labels rather than sizing navigation around the current English strings.

## Acceptance and verification

### Agent gate

- Router and LiveView tests cover every current URL, direct Decision links, active-route matching, absent Build Order registration, back/forward, theme, and read-only/writable presentation.
- BO-008 browser and accessibility tests cover 320/390/768/960/desktop widths, 200% text zoom, keyboard and touch navigation, safe-area padding, visible focus, reduced motion, and no horizontal page clipping on the real LiveView route.
- Analytics tests prove the link performs normal document navigation and the real authenticated document still loads.

### At-merge gate

- Rebase on the resolved configured integration target, verify it contains the
  completed #1034 terminology sweep, reconcile the single shell/CSS owner, and
  pass router, dashboard, Analytics, asset, accessibility, and full CI gates.

### Human/manual evidence

- From the Executor repository root, drive the real `scripts/aiurdev --test` dashboard and navigate every destination at desktop and 390px with keyboard and touch emulation; capture that no bottom navigation obscures content.

## Failure, security, migration, and accessibility cases

- Provider or route unavailability renders a named unavailable state without activating a dead link.
- Preserve all current security pipelines and safe external-link behavior; this ticket adds no mutation surface.
- Keep existing URLs and direct links compatible. No stored-data migration is allowed.
- Navigation uses semantic `nav`/links, `aria-current`, visible focus, at least 44px touch targets, and non-color-only active state.

## Surfaces

- Reads: current route/action, endpoint availability, dashboard status and theme state.
- Writes: shared shell, route registry, navigation/header components, CSS, and tests.
- Contracts: dashboard route metadata, route registration, responsive content offsets.

## Sibling boundaries and open gates

BO-008 is a hard predecessor only for the shared Phoenix/LiveView browser
harness. DASH-003, DASH-005, DASH-007, DASH-021, DASH-022, and
DASH-015 consume this shell directly or transitively but own their content.
This ticket declares the symmetric `serializes_with: BO-012` edge because
both tickets write the OCC route/navigation shell. If the
configured implementation base does not yet contain closed #1034, the shared
predecessor-baseline gate—not a new feature ticket—must be resolved before
pickup.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-001`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

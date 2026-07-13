# DASH-001 — Ship responsive route-aware shell

**Kind:** executable

**Provenance:** planned in plan v1 after refreshed-prototype and current-main review

**Complexity:** 3 — Shared route metadata and responsive navigation across unlike route types

**Risk:** medium

**Depends on:** GitHub #1034 (Executor terminology sweep)

**Serializes with:** active dashboard shell, navigation, and shared CSS branches

**Requirements:** DREQ-001

**Researched at:** `b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

The Executor Control Center has URL-backed desktop and mobile navigation with a truthful per-route header for Units, Commands, the registered Build Order route, and the existing Analytics document, without clipping or client-only tab state.

## Context and evidence

Current main exposes LiveView routes at `/`, `/decisions`, and `/decisions/:decision_id`, plus a controller-backed secure Analytics document at `/analytics`. The refreshed prototype demonstrates a desktop sidebar and mobile bottom navigation but treats Analytics as a fake client panel and clips navigation at narrow widths. GitHub #1034 owns the user-facing Operator-to-Executor rename; this ticket must consume that terminology rather than reintroduce old copy.

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

Extend `AiurWeb.DashboardLive`, `AiurWeb.Layouts`, `AiurWeb.Router`, the current dashboard asset pipeline, and `TelemetryDashboardController`. Reuse the authentication and writable/read-only contracts established on current main.

## Contract and invariants

- The URL and current route/action are the only source of selected navigation state; browser-local tab state is not authoritative.
- Every registered destination has one accessible name, one active-match policy, and an appropriate navigation primitive for its route type.
- DOM order equals visual and screen-reader order. Navigation, theme, status, and view content remain reachable at 320, 390, 768, and 960 CSS pixels and at 200% text zoom.
- No shell component invents provider, ETA, spend, progress, live, or authentication values.
- Existing Basic Auth, supervisor authentication, CSRF, secure-document, and writable gates remain unchanged unless a later ticket explicitly strengthens the financial-data boundary.

## Refreshable implementation notes

- Refresh GitHub #1034 and any open dashboard PRs at pickup; merge or rebase the accepted Executor terminology before editing shared copy.
- Likely extract HEEx components and route metadata rather than expanding the already-large `DashboardLive.render/1`.
- Use CSS logical properties and `env(safe-area-inset-bottom)` where supported. Test long localized labels rather than sizing navigation around the current English strings.

## Acceptance and verification

### Agent gate

- Router and LiveView tests cover every current URL, direct Decision links, active-route matching, absent Build Order registration, back/forward, theme, and read-only/writable presentation.
- Browser and accessibility tests cover 320/390/768/960/desktop widths, 200% text zoom, keyboard and touch navigation, safe-area padding, visible focus, reduced motion, and no horizontal page clipping.
- Analytics tests prove the link performs normal document navigation and the real authenticated document still loads.

### At-merge gate

- Rebase on the completed #1034 terminology sweep and current main, reconcile the single shell/CSS owner, and pass router, dashboard, Analytics, asset, accessibility, and full CI gates.

### Human/manual evidence

- From the operator repository root, drive the real `scripts/aiurdev --test` dashboard and navigate every destination at desktop and 390px with keyboard and touch emulation; capture that no bottom navigation obscures content.

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

DASH-003, DASH-005, DASH-007, and DASH-015 consume this shell but own their content. Build Order registers its route without making this ticket part of Build Order acceptance. Pickup is blocked until #1034's user-facing terminology decision is available on the implementation base.

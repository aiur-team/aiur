# DASH-001 — Ship responsive dashboard shell

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Shared route-aware layout across existing dashboard views

**Risk:** medium

**Depends on:** none

**Requirements:** DREQ-001

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

The dashboard uses URL-backed responsive navigation and per-view headers for Units, Commands, Build Order when registered, and the existing Analytics route, with no client-only tab state or unreachable mobile item.

## Context and evidence

The refreshed prototype replaces page tabs with a desktop sidebar and mobile bottom navigation, but also regresses the real Analytics capability and clips the fourth item at 390px. Production should adopt the hierarchy while preserving current authenticated routes, operational metadata, theme access, and read-only meaning.

## Scope

- Create one route metadata/navigation component with real links and `aria-current`; registered routes appear without hard-coded client tab switching.
- Implement sticky desktop and reachable mobile navigation plus per-view icon/title/header composition at 320, 390, 768, 960, and desktop widths.
- Preserve `/`, `/decisions`, `/decisions/:decision_id`, `/analytics`, Basic Auth, writable/read-only status, live/offline truth, tracker/agent meaning, theme, and back/refresh behavior.
- Define the extension seam BO-009 uses to register Build Order without rewriting the shell.

## Non-goals

- Implement Build Order content, Units read model/controls, Commands composition, usage cards, or replace Analytics with a placeholder.
- Copy visual DOM reordering or hide status/theme access on mobile.

## Existing owner and reuse target

Extract shared HEEx/components from `AiurWeb.DashboardLive` and `AiurWeb.Layouts`; preserve `AiurWeb.Router`, `TelemetryDashboardController`, and existing auth contracts.

## Contract and invariants

- Navigation state is derived from the current route/action and represented in the URL.
- Every registered item is reachable and named at all supported widths; absent future routes are not active broken links.
- DOM order matches visual/read order and no page-level horizontal clipping hides facts/actions.

## Refreshable implementation notes

- Refresh BO-009 and active dashboard PRs at pickup; one branch owns shared shell/CSS.
- Keep route metadata declarative so Build Order can add itself later.

## Acceptance and verification

### Agent gate

- LiveView/router tests cover each current route, deep links, selected state, Basic Auth/read-only behavior, and existing Analytics.
- Browser tests cover 320/390/768/960/desktop, keyboard/touch, theme/status access, no clipping, and reduced motion.

### At-merge gate

- Current-base dashboard, router, analytics, asset, accessibility, and full CI pass.

### Human/manual evidence

- Reviewer navigates every view at desktop and 390px with keyboard and touch emulation.

## Failure, security, migration, and accessibility cases

- Preserve authenticated boundaries and safe external links; no new mutation surface.
- Keep existing URLs/redirects compatible.
- Use semantic navigation, visible focus, target sizes, and DOM/visual order parity.

## Surfaces

- Reads: current dashboard routes/layout/design tokens.
- Writes: shared shell/navigation/page-header components and CSS.
- Contracts: route metadata and responsive navigation.

## Sibling boundaries and open gates

DASH-002/003/004/008 consume the shell. BO-009 registers Build Order. Sequence shared CSS changes rather than merging parallel shell forks.


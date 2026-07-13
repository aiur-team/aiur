# BO-007 — Integrate accessible graph layout platform

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — New vendored browser worker and LiveView layout adapter

**Risk:** high

**Phase hint:** 2

**Depends on:** BO-001

**Serializes with:** none

**Requirements:** BOREQ-008, BOREQ-010, BOREQ-012

**Decisions:** DEC-007

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`, `phase:2`, `build-lane:frontend`; never `agent:todo`

## Outcome

Aiur has a pinned, locally served, layout-only graph engine and one tested LiveView hook adapter that computes lane/phase-constrained coordinates and routed edges off the main thread while leaving cards server-rendered and focusable.

## Context and evidence

Aiur currently has no application JavaScript bundle or graph dependency. Static assets are embedded explicitly, LiveView hooks are registered inline, and regression tests assert the current asset surface.

ELK.js is the prescriptive starting engine because its layered algorithm targets directed graphs and routed edges and it supports browser Web Workers. The engine computes geometry only; product state, semantic DOM, focus, styling, and edge meaning remain Aiur-owned.

## Scope

- Pin and vendor an audited ELK.js release plus license metadata; serve its API/worker assets locally with deterministic release packaging and no CDN/runtime network fetch.
- Define one adapter input/output contract for stable node dimensions, lane/phase constraints, ports, coordinates, routed edge sections, bounds, and structured layout failure.
- Run maximum-fixture layout in a Web Worker and provide cancellation/generation guards so stale async results never overwrite newer LiveView data.
- Register one LiveView hook that measures server-rendered cards, invokes the adapter, applies transforms/SVG geometry, and redraws after LiveView patches, resize, font readiness, theme, and card-content changes.
- Keep cards in semantic server-rendered DOM and define deterministic no-worker/layout-error fallback behavior.
- Prove representative 20, 50, and 100-node lane-by-phase fixtures before any page depends on the platform.

## Non-goals

- Render the Build Order route, fetch data, own graph status/edge semantics, or implement the final interaction polish.
- Adopt canvas-only nodes, fetch third-party scripts at runtime, or copy the prototype's fixed coordinates.
- Build a general-purpose package manager pipeline unless required for reproducible vendoring.

## Existing owner and reuse target

Extend `AiurWeb.StaticAssets`, its controller/router, `AiurWeb.Layouts` hook registry, release external resources, and dashboard CSS/test seams. Reuse the current embedded-asset strategy; update `extensions_test.exs` and compile-time path coverage intentionally instead of bypassing them.

## Contract and invariants

- Vendored bytes, version, license, and SHA are reproducible and served behind existing dashboard authentication.
- ELK/layout code receives normalized geometry only and cannot mutate application state or decide dependency satisfaction.
- Every async request carries a generation; obsolete results are discarded and workers are terminated on hook destruction.
- DOM order remains semantic and independent of visual coordinates. Layout failure retains usable cards and an explicit diagnostic.
- At 100 nodes, layout work does not create a material main-thread stall under the documented budget.

## Refreshable implementation notes

- Refresh the current ELK.js release and API at pickup; use the pinned reviewed release rather than `@next`.
- Likely split vendor serving, adapter/hook, and fixture helpers into small files because current inline layout script is already a shared seam.
- Measure real card dimensions; do not hard-code the prototype's illustrative dimensions as a domain rule.

## Acceptance and verification

### Agent gate

- Asset tests verify authenticated local serving, exact pinned checksum/content type/cache behavior, missing asset handling, and release inclusion.
- JavaScript/browser tests cover worker success/failure/cancellation, stale generations, routed edges, resize/font/theme/LiveView updates, deterministic fallback, and 20/50/100 fixtures.
- Accessibility tests prove cards remain buttons/links in semantic DOM and geometry code does not change tab order.

### At-merge gate

- Static asset, router, layout, compile-path, browser, and current-base full CI gates pass.
- Recorded performance evidence shows worker layout and interaction budgets at 100 nodes on the supported browser baseline.

### Human/manual evidence

- Reviewer inspects the 20/50/100 fixture render in light and dark themes and confirms layout failures leave a readable non-overlapping fallback.

## Failure, security, migration, and accessibility cases

- Security: no CDN, dynamic code evaluation, unsafe URL, or credential-bearing worker message.
- Migration: existing Phoenix assets and AgentLog hook remain functional; new assets are additive and pinned.
- Accessibility: cards stay server-rendered/focusable; visual placement never becomes reading order, and reduced motion disables animated geometry changes.

## Surfaces

- Reads: Build Order domain geometry contract; server-rendered node measurements; pinned ELK.js release.
- Writes: vendored graph assets; StaticAssets/router/layout hook integration; layout adapter and browser fixtures.
- Contracts: layout adapter input/output; worker lifecycle; geometry failure fallback.

## Sibling boundaries and open gates

BO-009 consumes this adapter and owns page composition. BO-010 owns final pan/zoom/selection behavior. Companion shell work may touch Layouts/CSS; refresh and sequence those branches before pickup rather than duplicating navigation.


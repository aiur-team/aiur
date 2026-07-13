# BO-010 — Harden graph interaction and scale

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Cross-input accessibility, live redraw, and 100-node performance

**Risk:** high

**Phase hint:** 6

**Depends on:** BO-009

**Serializes with:** none

**Requirements:** BOREQ-008, BOREQ-009, BOREQ-010, BOREQ-011, BOREQ-012

**Decisions:** DEC-007

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`, `phase:6`, `build-lane:frontend`; never `agent:todo`

## Outcome

The Build Order graph remains understandable, operable, and responsive with mouse, keyboard, touch, assistive technology, live patches, narrow viewports, reduced motion, and representative 20/50/100-ticket DAGs.

## Context and evidence

The prototype demonstrates density and edge highlighting but lacks its documented pan/zoom controls, drops missing endpoints, uses mouse-only card divs, and clips summary/nav content at 390px. Production must implement the interaction idea and correct those defects.

This ticket starts only after the minimum route is real, keeping polish/performance work from hiding provider or domain changes.

## Scope

- Implement fit-to-view, 40–160% bounded zoom, pointer pan, wheel/trackpad zoom, accessible keyboard controls, reset, and persistent selected-node state per root.
- Highlight upstream/downstream closure on hover, focus, and persistent touch/activation; keep cleared, blocking, terminal-unsatisfied, unknown, external, and cyclic edge states distinguishable without color alone.
- Define keyboard traversal and visible focus for cards/controls, accessible graph summary/relationships, reduced-motion-safe transitions, and announcements that do not become noisy on live updates.
- Make redraw robust after LiveView patches, node/content size changes, font readiness, theme, viewport resize, and async generation races.
- Prove responsive behavior at 320/390/768/960 plus desktop: no page-level clipping and only the graph viewport intentionally scrolls/pans in two dimensions.
- Measure and meet documented layout, initial render, patch, pan/zoom, focus, and dialog interaction budgets for 20, 50, and 100-ticket fixtures.

## Non-goals

- Change GitHub/provider contracts, status precedence, dependency truth, or add graph editing.
- Optimize by hiding tickets/edges/diagnostics, truncating accessible titles, or virtualizing focusable nodes without an accepted accessibility design.
- Implement the companion Units filters, usage summary, or Analytics redesign.

## Existing owner and reuse target

Harden the BO-007 hook/layout adapter and BO-009 page/components. Keep business semantics in BO-006 and server-rendered HEEx; JavaScript owns geometry and canvas interaction only.

## Contract and invariants

- Every mouse-only interaction has keyboard and touch equivalents; information is not conveyed by color or hover alone.
- Fit/zoom/pan never move focus offscreen without a recovery control, and bounds remain enforced after resize/root change.
- LiveView generation guards prevent stale layout from applying to newer data.
- Reduced-motion preference is observed live, not captured only once at page load.
- Performance budgets and fixture shapes are recorded as evidence, not subjective claims.

## Refreshable implementation notes

- Use browser automation appropriate to the repo; refresh available tooling at pickup.
- Test real fonts/themes/card content rather than geometry-only placeholders.
- Preserve full title in accessible name/detail when visual cards use two-line clamping and a `Cx:N` pill.

## Acceptance and verification

### Agent gate

- Browser tests cover mouse, keyboard, touch/pointer, focus chain selection, dependency dialog navigation, fit/zoom/pan/reset bounds, resize/theme/font/LiveView redraw, stale async generation, and reduced-motion changes.
- Automated accessibility checks plus semantic assertions cover edge legends, graph summary, focus order/visibility, modal return, non-color states, and narrow viewports.
- Performance harness records 20/50/100 fixture results and fails on the accepted budgets.

### At-merge gate

- All browser/LiveView/layout/accessibility suites and current-base full CI pass on the integrated dashboard.
- At-merge evidence includes light/dark/reduced-motion and 390px/desktop captures plus recorded 100-node timings.

### Human/manual evidence

- Reviewer completes the core graph workflow using keyboard only and touch/pointer emulation, then inspects 390px and 100-node results for clipping, lost actions, or misleading edges.

## Failure, security, migration, and accessibility cases

- Security: interaction state contains only root/node IDs and geometry, never issue bodies or credentials in persistent browser storage.
- Migration: progressive enhancement keeps a readable fallback if worker/hook fails.
- Accessibility: screen-reader summaries, focus, target size, contrast, motion, zoom, and touch behavior are acceptance gates.

## Surfaces

- Reads: minimum Build Order page; layout adapter and view model; prototype design tokens/behavior.
- Writes: graph hook and interaction controls; responsive/accessibility CSS; browser/performance fixtures.
- Contracts: pan/zoom/selection behavior; responsive graph viewport; 100-node performance budget.

## Sibling boundaries and open gates

BO-009 owns route/data composition. BO-011 owns merged-base proof. Any provider or domain defect found here returns to the owning ticket unless it directly blocks acceptance.


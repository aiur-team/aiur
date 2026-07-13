# BO-013 — Harden graph interaction and accessibility

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Unified mouse, keyboard, touch, focus, zoom, and dependency-chain interaction

**Risk:** high

**Phase hint:** 6

**Depends on:** BO-008, BO-012

**Serializes with:** BO-020, DASH-023 — shared Build Order route component and CSS

**Requirements:** BOREQ-011, BOREQ-013, BOREQ-014

**Decisions:** DEC-007, DEC-008

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex-gpt-5.6-sol`, `phase:6`, `build-lane:dashboard-ui`; never `agent:todo`

## Outcome

The real Build Order graph has equivalent, discoverable mouse, keyboard, touch,
and assistive-technology workflows for navigation, selection, dependency-chain
inspection, fit/pan/zoom, and ticket context, with stable focus and no
color-only or hover-only information.

## Context and evidence

The prototype highlights dependency chains on mouse hover and uses clickable
`div` cards. It lacks focus/touch parity and working zoom controls. A production
graph must remain a semantic document while supporting a two-dimensional visual
workspace. Interaction cannot change product truth or become inaccessible when
layout falls back.

## Scope

- Implement bounded 40–160% zoom, explicit `+`/`-`/fit controls, wheel/trackpad
  zoom with appropriate modifier/default-scroll policy, pointer pan on the
  canvas background, keyboard panning, and deterministic reset on root change.
- Define semantic card focus/navigation order independent of visual coordinates,
  visible focus, Enter/Space context activation, Escape behavior, and a
  discoverable shortcut/help description.
- Highlight the selected/focused/hovered node plus upstream/downstream closure
  without changing DOM order or edge truth. Hover is transient; focus and touch
  activation provide equivalent persistent inspection and clear/deselect paths.
- Express `cleared`, `blocking`, `terminal_unsatisfied`, `unknown`, and `cyclic`
  edges through text/shape/pattern/marker semantics as well as color, preserving
  readiness precedence from BO-007.
- Add accessible graph/selection/dependency summaries and live announcements
  that are concise and coalesced, not one announcement per moving node/update.
- Preserve BO-011 context focus trap, replacement navigation, close restoration,
  no-mutation boundary, and safe destination links across canvas interaction
  and LiveView patches.
- Honor live reduced-motion and forced-colors/high-contrast preferences; disable
  nonessential animated transitions without disabling interaction.

## Non-goals

- Change graph/provider/readiness data, edit GitHub planning relationships,
  implement minimap/filter-bar/search, or tune final 100-node redraw budgets.
- Make arbitrary visual nearest-neighbor navigation the only keyboard path.
- Capture wheel/touch gestures outside the graph or prevent ordinary page
  scrolling when the user is not intentionally interacting with the canvas.

## Existing owner and reuse target

Extend BO-012's semantic cards/routes, BO-010's geometry adapter, BO-011's
context component, current dashboard focus/theme conventions, and BO-008's real
browser/a11y harness. Keep one interaction state owner per selected root.

## Contract and invariants

- Every mouse-only operation has keyboard and touch-equivalent access to the
  same information and result.
- Interaction state is keyed by canonical root/node and reconciled after data
  generations; missing selections clear safely and focus moves predictably.
- Pan/zoom/highlight never changes node/edge/readiness/lifecycle truth or hides
  the semantic dependency summary.
- DOM/tab/read order remains logical and stable regardless of SVG coordinates.
- Reduced motion, forced colors, theme, zoom, and fallback remain functional
  states rather than afterthought styles.

## Refreshable implementation notes

- Refresh browser support, current hook events, dialog/focus helpers, and design
  tokens on the configured integration branch before choosing key bindings.
- Keep input-policy and selection reducers pure/testable; the hook applies
  transforms and reports state but does not invent adjacency.
- Use ARIA only where native elements do not express the contract; avoid a
  custom `application` role that suppresses ordinary document navigation.

## Acceptance and verification

### Agent gate

- BO-008 browser tests cover mouse, keyboard, touch emulation, wheel/trackpad,
  `+`/`-`/fit, bounds, page-scroll coexistence, root switch, selection removal,
  reconnect, fallback, and every dependency-chain direction/state.
- Automated accessibility plus component tests cover semantic controls, names,
  tab/read order, focus visibility/trap/restore, concise announcements,
  non-color states, reduced motion, forced colors, theme, and 200% text zoom.
- Tests prove hover/focus/touch parity and that no interaction invokes a GitHub
  planning or Aiur runtime mutation.

### At-merge gate

- Hook/component/browser/accessibility/static tests and full repository CI pass
  on the current configured integration branch with no regressions to existing
  dashboard navigation or context actions.
- Interaction documentation and shortcut/help text match shipped behavior.

### Human/manual evidence

- Reviewer completes root/card/chain/context/zoom/pan workflows using keyboard
  only and touch emulation, then checks reduced motion, forced colors, light and
  dark themes. BO-015 records final evidence.

## Failure, security, migration, and accessibility cases

- Ignore malformed/stale node IDs and bound transform values; never interpolate
  issue content into selectors, CSS, SVG markup, or announcements unsafely.
- No persisted migration; client interaction state is disposable and scoped to
  the current root/generation.
- Accessibility is the primary scope: native controls, 44px touch targets,
  visible focus, logical order, non-color states, concise announcements, and
  fallback parity are required.

## Surfaces

- Reads: BO-012 semantic graph and adjacency; BO-010 geometry/fallback;
  BO-011 context/focus contract; input/theme/motion/viewport state.
- Writes: interaction reducers/hook events, controls, highlight/transform
  styles, Build Order route component CSS, accessible
  summaries/help/announcements, and browser tests.
- Contracts: root-scoped interaction state; input equivalence; dependency-chain
  selection; pan/zoom bounds and focus behavior.

## Sibling boundaries and open gates

BO-014 owns responsive redraw and measured scale, not interaction semantics.
The sibling DASH-023 member declares the serialization edge for Build Order
route component CSS. It is not a hard prerequisite and may not redefine these
controls.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-013`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.

# BO-014 — Prove responsive redraw, scale, and performance

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Responsive lifecycle hardening and measured 100-member performance

**Risk:** high

**Phase hint:** 7

**Depends on:** BO-008, BO-013

**Serializes with:** BO-020 — shared Build Order route component and CSS

**Requirements:** BOREQ-008, BOREQ-010, BOREQ-013, BOREQ-014

**Decisions:** DEC-007

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex`, `phase:7`, `build-lane:frontend`; never `agent:todo`

## Outcome

Build Order remains readable, responsive, leak-free, and input-responsive across
supported narrow/mobile/desktop viewports and 20/50/100-member graphs while
fonts, containers, LiveView data, theme, motion, and viewport geometry change.

## Context and evidence

A correct first layout is insufficient. Sidebars, mobile navigation, web fonts,
text wrapping, context dialogs, root changes, reconnects, and live data patches
all change card measurements. Naive observer loops can repeatedly relayout or
apply stale geometry, while a 100-node main-thread layout can freeze input.
This ticket owns measurable final hardening after interaction semantics are
stable.

## Scope

- Observe relevant container/card/font/viewport/LiveView changes and coalesce
  them into generation-safe measurement/layout work without feedback loops,
  duplicate observers, or one layout per node mutation.
- Preserve current pan/zoom/selection when compatible; refit or clear it by an
  explicit policy after root/data/viewport changes. Never retain a selection
  that no longer resolves.
- Reflow navigation, headers, lanes, cards, diagnostics, controls, context, and
  fallback at 320, 390, 768, 960, and desktop widths plus 200% text zoom. Honor
  safe-area insets and prevent page-level clipping; only the graph viewport may
  pan intentionally in two dimensions.
- Measure worker time, end-to-visible-layout, main-thread long tasks/input
  responsiveness, redraw count, memory/worker/observer cleanup, and LiveView
  update behavior on deterministic 20/50/100 fixtures.
- Commit explicit CI/reference-device budgets and variance methodology before
  optimization. At minimum, the 100-member fixture must produce first useful
  semantic content immediately, complete worker-backed geometry within 2
  seconds on the recorded CI reference, introduce no graph-caused main-thread
  task longer than 100 ms, and settle a single logical update without an
  unbounded relayout loop.
- Optimize serialization, measurement, rendering, routing, and redraw only
  within existing contracts; expose visible fallback/health if a hard budget or
  worker timeout is exceeded.
- Record sanitized performance evidence and regression thresholds in BO-008's
  harness rather than relying on subjective smoothness.

## Non-goals

- Add minimap, filtering, virtualization that removes focused semantic cards,
  WebGL/canvas-only rendering, server/provider changes, or new product data.
- Weaken accessibility, edge diagnostics, fallback, or state truth to hit a
  benchmark.
- Treat one developer-machine run or prototype screenshot as scale proof.
- Edit shared OCC shell, Units, or Commands CSS; responsive changes stay inside
  the Build Order route component namespace.

## Existing owner and reuse target

Harden BO-010's adapter, BO-012's page, BO-013's interaction, current responsive
dashboard tokens/shell, and BO-008's fixture/measurement infrastructure. Keep
performance policy in tests and documented evidence, not magic delays.

## Contract and invariants

- One logical data/measurement change causes bounded coalesced layout work;
  observer callbacks cannot create a self-sustaining loop.
- Worker/observer/listener resources are released on root switch, reconnect,
  hook destroy, and route exit; stale work never applies.
- Semantic DOM and controls remain usable while layout is pending or degraded.
- Responsive visual order matches DOM/read order, and no fact/action becomes
  unreachable at narrow widths or 200% zoom.
- Performance degradation changes health/fallback, never graph truth or
  dependency readiness.

## Refreshable implementation notes

- Record baseline measurements on the current configured integration branch and
  CI runner before tuning; adjust the numeric budget only through reviewed
  evidence, not silent test relaxation.
- Prefer event-driven font/observer/worker readiness and animation-frame
  coalescing over fixed sleeps/debounce delays.
- Sequence Build Order route component CSS with DASH-023 while retaining
  independent acceptance. Do not edit shared OCC shell, Units, or Commands CSS.

## Acceptance and verification

### Agent gate

- BO-008 browser runs cover every target viewport, 200% text zoom, safe areas,
  theme/motion changes, font load, container resize, orientation/viewport
  change, LiveView patch/reconnect, root switch, context open/close, and fallback.
- 20/50/100 performance runs assert recorded budgets, long tasks, redraw bounds,
  worker/main-thread separation, input during layout, and cleanup after repeated
  navigation; failure cannot be retried into a pass without preserved evidence.
- Accessibility/regression tests prove no clipping, DOM/visual-order mismatch,
  lost focus/selection, hidden diagnostics, or reduced-motion violation.

### At-merge gate

- Repeated browser/performance/a11y runs and full repository CI pass on the
  current configured integration branch with committed budget/evidence notes.
- Packaged local assets exhibit the same worker/redraw lifecycle as development
  and leave no process/resource leak after route exit.

### Human/manual evidence

- Reviewer exercises 20/50/100 graphs at desktop and 390px, resizes and changes
  theme/motion/text zoom during layout, and confirms input/fallback remain
  usable. BO-015 records final acceptance evidence.

## Failure, security, migration, and accessibility cases

- Performance artifacts use synthetic data and omit credentials, real issue
  bodies, account facts, local paths, hosts, and raw provider errors.
- No persisted migration; client resources are disposable and generation-bound.
- Responsive reflow, 200% zoom, safe areas, 44px controls, focus continuity,
  reduced motion, non-color diagnostics, and semantic fallback are required
  under both normal and degraded performance.

## Surfaces

- Reads: BO-010/012/013 layout/page/interaction state; font/container/viewport
  lifecycle; BO-008 fixtures and measurement API.
- Writes: observer/coalescing/redraw lifecycle, responsive CSS, performance
  budgets/tests/evidence, Build Order route component CSS, health/fallback
  tuning, and cleanup checks.
- Contracts: redraw triggers/coalescing; root/viewport state preservation;
  20/50/100 performance and responsive acceptance budgets.

## Sibling boundaries and open gates

BO-015 owns merged real/synthetic proof. Companion responsive shell work may be
reused but this ticket does not edit its shared CSS. The standalone DASH-023
companion declares the cross-pack serialization edge for Build Order route
component CSS and cannot relax these budgets or become part of Build Order
completion.

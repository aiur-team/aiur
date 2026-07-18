# BO-014 — Performance and scale evidence

Committed budgets, variance methodology, and recorded baselines for the Build
Order graph at 20/50/100 members. These budgets are asserted by
`src/browser/tests/build-order-performance.browser.spec.mjs`; a regression flips
those assertions and cannot be retried into a pass without updating the evidence
here. Responsive acceptance is asserted separately by
`src/browser/tests/build-order-responsive.browser.spec.mjs`.

All data is synthetic. The fixtures (`Aiur.BrowserHarness.Fixtures`,
`test/browser/fixture_server.exs`) carry no credentials, real issue bodies,
account facts, local paths, hosts, or provider errors.

## What is measured

The graph lays out off the main thread: the LiveView renders every semantic card
in document flow immediately, a Web Worker (vendored ELK) computes geometry, and
the adapter applies it. The metrics below separate those concerns:

- **`workerDurationMs`** — pure worker geometry round-trip, reported as
  `durationMs` on the `aiur:layout-health` `ready` event (measured from the
  adapter's `startedAt` to apply). This is "worker-backed geometry" and is the
  metric the ticket's hard 2s budget governs.
- **`endToVisibleMs`** — navigation start to `ready`. Additionally includes the
  one-time page load, LiveView connect, worker spawn, and asset fetch. An
  end-to-end regression guard, not the geometry budget.
- **redraw main-thread block** — total long-task time (`PerformanceObserver`
  `longtask`) for one resize → worker relayout → apply cycle on a 100-member
  graph, isolated from LiveView morphdom by dispatching a pure `resize`.
- **requests per trigger** — count of worker layout requests
  (`aiur:layout-lifecycle` `request`) produced by one logical trigger.
- **teardown lifecycle** — `client_disposed` / `destroyed` counts across
  repeated unmount/remount, captured through the adapter `onLifecycle` option
  seam (teardown fires on a detached element, so a bubbling DOM listener would
  miss it and pass on zero).

## Variance methodology

- Budgets are **maximum** bounds, not means, so a single slow sample fails rather
  than being averaged away.
- Timing samples are taken **steady state**: the redraw measurement discards
  warm-up iterations (JIT cold starts run materially slower — the first redraw
  after load is ~1.5× a warm one) before recording repetitions.
- Baselines below were recorded across repeated runs (3 samples per size for the
  geometry metrics, 4 post-warmup repetitions for redraw). Budgets sit above the
  recorded maximum with headroom for the CI reference, which is not identical to
  the recording workstation.
- **The recording host is a developer workstation (Chromium via Playwright), not
  the CI reference device.** Numbers are indicative; the authoritative baseline
  must be re-recorded on the configured integration branch's CI runner. Adjust a
  numeric budget only through reviewed evidence recorded here — never silent test
  relaxation.

## Recorded baselines (developer workstation, indicative)

| members | worker geometry (ms) | end-to-visible (ms) | redraw main-thread block (ms) |
| ------- | -------------------- | ------------------- | ----------------------------- |
| 20      | 880–1151             | 1276–1648           | —                             |
| 50      | 1022–1107            | 1714–1831           | —                             |
| 100     | 1135–1227            | 1989–2102           | 103–135 (steady state)        |

Worker geometry for the 100-member graph settles in ~1.2s — well inside the 2s
budget. End-to-visible for 100 members hovers near 2.0–2.1s, dominated by ~0.85s
of one-time page/asset/worker cold start on top of the ~1.2s of geometry.

## Committed budgets

| budget                         | value  | rationale                                                                                             |
| ------------------------------ | ------ | ---------------------------------------------------------------------------------------------------- |
| worker geometry (all sizes)    | 2000ms | Ticket hard budget (BOREQ-010). Recorded max ~1.2s at 100 members.                                    |
| end-to-visible (all sizes)     | 3000ms | End-to-end guard incl. one-time cold start (~0.85s) on top of geometry. Recorded max ~2.1s.           |
| requests per logical trigger   | ≤ 2    | In-flight coalescing collapses a burst to one settled worker pass (plus at most one trailing pass).   |
| redraw main-thread block (100) | 200ms  | Recorded single-remeasure reference ~135ms + CI-variance headroom (see note below).                  |

### Note on the redraw main-thread block

A redraw forces one **natural remeasure**: the adapter strips applied geometry
from every card and reads their flow sizes, forcing a single reflow of all 100
cards. That ~120–135ms cost is inherent to the existing BO-010 measurement
architecture, not introduced by BO-014 — it is present in the BO-013 baseline.
BO-014's contribution is **in-flight coalescing**: a burst of observer/resize
triggers now collapses to one trailing remeasure instead of stacking several
back-to-back, so the main thread is never held by a self-sustaining relayout
loop and input keeps a slice of the thread between redraws. The 200ms budget
bounds one such remeasure; smaller graphs stay under the 100ms
input-responsiveness target. This budget governs a single redraw's block, not a
per-node cost, and is the metric to re-baseline on the CI reference.

## Fixture scale shape

The 20-member fixture (the default, used by BO-013/route/interaction specs) is
unchanged: four partition columns, phase cycling every two cards, star edges. The
50/100-member fixtures fill a balanced ~sqrt(size) grid — `per_phase` consecutive
cards per partition column, each card depending on the same row of the next
column. `elk.partitioning` maps phase directly onto a layered column, so a graph
crammed into too few columns overflows vertically and one spread across too many
columns (or a star of long edges fanning from two roots) stacks ELK routing dummy
nodes vertically until a coordinate exceeds the worker's 4095px `MAX_COORDINATE`
bound. The balanced grid keeps both the column count and the per-column stack near
sqrt(size), so every coordinate stays in bounds and 100 members produce real
worker geometry instead of a false `layout_overflow` fallback. Edge count per
size is preserved so sibling adapter specs stay pinned.

## Cleanup / leak evidence

Repeated unmount → remount navigation (3 cycles) disposes the worker client and
destroys the hook on every unmount (`client_disposed` and `destroyed` ≥ cycles),
and the hook count returns to 1 on remount — no orphaned worker, observer, or
listener survives a route/graph exit.

## Reproduce

```
cd src/browser
node scripts/run-browser-tests.mjs tests/build-order-performance.browser.spec.mjs
node scripts/run-browser-tests.mjs tests/build-order-responsive.browser.spec.mjs
```

Both are wired into `npm test` (`test:performance`, `test:responsive`) for CI.

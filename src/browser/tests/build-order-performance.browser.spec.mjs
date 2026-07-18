import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { measureBrowserWork } from './support/measurements.mjs'
import { openFixture } from './support/browser-helpers.mjs'

// BO-014 performance and scale budgets. These are committed CI-reference
// budgets, not developer-machine smoothness. The variance methodology and the
// baseline evidence they were derived from live in
// docs/build-order/bo-014-performance-evidence.md. A regression flips these
// assertions; it cannot be retried into a pass without preserved evidence.
const SIZES = [20, 50, 100]

const BUDGETS = {
  // Hard budget (BOREQ-010): worker-backed geometry must settle within 2s on the
  // CI reference for every fixture size, including the 100-member graph. This is
  // the pure ELK worker round-trip reported as `durationMs` on the ready health
  // event, isolated from one-time page/asset/worker cold-start. Recorded
  // baseline max is ~1.2s at 100 members (see the evidence doc).
  workerGeometryMs: 2_000,
  // End-to-visible (navigation start -> ready health) additionally carries the
  // fixed page-load, LiveView connect, and worker-spawn cost (~0.85s on the
  // recorded baseline, so ~2.0-2.1s at 100 members). Bounded generously as an
  // end-to-end regression guard with CI-variance headroom; the authoritative
  // geometry budget above is what the ticket pins, not this cold-start-inclusive
  // number. Adjust only through reviewed evidence, never silent relaxation.
  endToVisibleMs: 3_000,
  // A single logical trigger must not fan out into an unbounded relayout loop.
  // With in-flight coalescing one trigger produces one settled worker pass.
  maxRequestsPerTrigger: 2,
  redraw: {
    // Recorded reference for the main-thread block of ONE 100-member redraw. A
    // redraw forces a single natural remeasure reflow of all cards — that cost
    // is the pre-existing BO-010 measurement architecture, not something BO-014
    // introduces; BO-014's coalescing bounds how OFTEN it runs (see the bounded
    // relayout test), not its per-pass cost. Baseline steady-state total block
    // is ~120-135ms at 100 members; smaller graphs stay under the 100ms
    // input-responsiveness target (evidence doc). Bounded here at 200ms with
    // CI-variance headroom. Adjust only through reviewed evidence, never silent
    // relaxation.
    maxLongTaskMs: 200,
    maxLayoutLatencyMs: 2_000
  }
}

async function instrumentedContext(browser, extraInit) {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  await context.addInitScript(() => {
    window.__aiurPerf = { start: performance.now(), health: [], lifecycle: [] }
    document.addEventListener('aiur:layout-health', ({ detail }) => {
      window.__aiurPerf.health.push({ ...detail, at: performance.now() })
    })
    // Capture the adapter lifecycle through the harness option seam rather than
    // the bubbling `aiur:layout-lifecycle` DOM event: teardown notifications
    // ('destroyed', 'client_disposed') fire while the hook element is already
    // detached during unmount, so a document-level listener never observes them
    // and the leak assertions would silently pass on zero. The onLifecycle
    // callback runs synchronously inside the adapter and sees every event.
    window.__aiurBrowserLayoutHookOptions = () => ({
      onLifecycle: (event, detail) => {
        window.__aiurPerf.lifecycle.push({ event, reason: detail && detail.reason ? detail.reason : null, at: performance.now() })
      }
    })
    window.__aiurBrowserHarnessOperations = {
      // Redraw via a pure resize observation → worker relayout → apply cycle,
      // isolating graph-layout main-thread cost from LiveView morphdom cost.
      redraw: () => new Promise((resolve) => {
        const done = ({ detail }) => {
          if (detail.health !== 'ready') return
          document.removeEventListener('aiur:layout-health', done)
          resolve()
        }
        document.addEventListener('aiur:layout-health', done)
        window.dispatchEvent(new Event('resize'))
      })
    }
  })
  if (extraInit) await context.addInitScript(extraInit)
  return context
}

async function loadSize(page, size) {
  await page.goto(`/fixture?size=${size}`)
  await expect(page.locator('#fixture-counts')).toContainText(`nodes: ${size}`)
}

for (const size of SIZES) {
  test(`Build Order graph renders semantic ${size}-member content immediately and settles worker geometry within budget`, async ({ browser }) => {
    const context = await instrumentedContext(browser)
    const page = await context.newPage()

    try {
      await openFixture(page)
      await loadSize(page, size)

      const root = page.locator('#fixture-build-order-graph')

      // First useful semantic content is available regardless of layout state:
      // every card and its dependency summary render in document flow up front.
      await expect(root.locator('[data-layout-node]')).toHaveCount(size)
      await expect(root.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()

      // Worker-backed geometry completes (not a fallback) for every size — the
      // 100-member graph must distribute across phase columns rather than
      // exceeding the worker coordinate bound.
      await expect(root).toHaveAttribute('data-layout-health', 'ready')
      await expect(root).not.toHaveAttribute('data-layout-failure', /.+/)

      const { endToVisibleMs, workerDurationMs } = await page.evaluate(() => {
        const ready = window.__aiurPerf.health.find((entry) => entry.health === 'ready')
        return { endToVisibleMs: ready.at - window.__aiurPerf.start, workerDurationMs: ready.durationMs }
      })

      test.info().annotations.push({ type: `perf-${size}`, description: `endToVisible=${Math.round(endToVisibleMs)}ms worker=${workerDurationMs}ms` })
      // The ticket's hard 2s budget is worker-backed geometry, isolated from
      // one-time cold start; end-to-visible is the looser end-to-end guard.
      expect(workerDurationMs, `worker geometry for ${size} nodes`).toBeLessThanOrEqual(BUDGETS.workerGeometryMs)
      expect(endToVisibleMs, `end-to-visible for ${size} nodes`).toBeLessThanOrEqual(BUDGETS.endToVisibleMs)
    } finally {
      await context.close()
    }
  })
}

test('a single logical trigger produces bounded, coalesced relayout work without a self-sustaining loop', async ({ browser }) => {
  const context = await instrumentedContext(browser)
  const page = await context.newPage()

  try {
    await openFixture(page)
    await loadSize(page, 100)
    const root = page.locator('#fixture-build-order-graph')
    await expect(root).toHaveAttribute('data-layout-health', 'ready')

    // One resize is one logical change. Count the worker layout requests it
    // triggers and prove the count stabilises (no observer feedback loop).
    const requestsAfter = async () => page.evaluate(() => window.__aiurPerf.lifecycle.filter((entry) => entry.event === 'request').length)
    const before = await requestsAfter()
    await page.evaluate(() => window.dispatchEvent(new Event('resize')))
    await expect(root).toHaveAttribute('data-layout-health', 'ready')

    const settled = await requestsAfter()
    await page.waitForTimeout(250)
    const stable = await requestsAfter()

    expect(stable, 'request count must stop growing (bounded loop)').toBe(settled)
    expect(settled - before, 'one trigger must coalesce to bounded worker passes').toBeLessThanOrEqual(BUDGETS.maxRequestsPerTrigger)
    expect(settled - before, 'the trigger must still redraw at least once').toBeGreaterThanOrEqual(1)
  } finally {
    await context.close()
  }
})

test('a 100-member redraw blocks the main thread only for one bounded remeasure', async ({ browser }) => {
  const context = await instrumentedContext(browser)
  const page = await context.newPage()

  try {
    await openFixture(page)
    await loadSize(page, 100)
    await expect(page.locator('#fixture-build-order-graph')).toHaveAttribute('data-layout-health', 'ready')

    // A pure resize -> worker relayout -> apply cycle isolates the graph-layout
    // main-thread cost from LiveView morphdom. Warm up first so the samples are
    // steady state, not JIT cold.
    const measurement = await measureBrowserWork(page, { operation: 'redraw', warmups: 4, repetitions: 4 })
    const blockPerRedraw = measurement.samples.map((sample) => (sample.longTasks ?? []).reduce((total, task) => total + task, 0))
    test.info().annotations.push({ type: 'redraw-block', description: `maxBlock=${Math.round(Math.max(0, ...blockPerRedraw))}ms samples=${measurement.samples.length}` })

    for (const sample of measurement.samples) {
      const blockedMs = (sample.longTasks ?? []).reduce((total, task) => total + task, 0)
      // The whole main-thread block of one redraw stays within the recorded
      // single-remeasure reference — it never fragments into runaway relayout
      // work, so input keeps a slice of the thread between redraws.
      expect(blockedMs, 'total main-thread block for one 100-node redraw stays within reference').toBeLessThanOrEqual(BUDGETS.redraw.maxLongTaskMs)
      expect(sample.layoutLatencyMs, 'redraw settles within the geometry budget').toBeLessThanOrEqual(BUDGETS.redraw.maxLayoutLatencyMs)
    }
  } finally {
    await context.close()
  }
})

test('worker and observer resources are released across repeated unmount and remount navigation', async ({ browser }) => {
  const context = await instrumentedContext(browser)
  const page = await context.newPage()

  try {
    await openFixture(page)
    await loadSize(page, 100)
    const root = page.locator('#fixture-build-order-graph')
    await expect(root).toHaveAttribute('data-layout-health', 'ready')

    const cycles = 3
    for (let index = 0; index < cycles; index += 1) {
      await page.locator('#unmount-graph').click()
      await expect(page.locator('#graph-unmounted')).toBeVisible()
      await expect(root).toHaveCount(0)
      await page.locator('#remount-graph').click()
      await expect(root).toHaveAttribute('data-layout-health', 'ready')
    }

    const lifecycle = await page.evaluate(() => window.__aiurPerf.lifecycle.map((entry) => entry.event))
    const disposals = lifecycle.filter((event) => event === 'client_disposed').length
    const destroys = lifecycle.filter((event) => event === 'destroyed').length

    // Every unmount tears the hook down and disposes its worker client — no
    // orphaned worker or observer survives a route/graph exit.
    expect(destroys, 'each unmount destroys the hook').toBeGreaterThanOrEqual(cycles)
    expect(disposals, 'each teardown disposes its worker client').toBeGreaterThanOrEqual(cycles)
    await expect(root).toHaveAttribute('data-layout-hook-count', '1')
  } finally {
    await context.close()
  }
})

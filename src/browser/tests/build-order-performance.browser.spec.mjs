import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { measureBrowserWork } from './support/measurements.mjs'
import { openFixture } from './support/browser-helpers.mjs'

// Performance and scale budgets for the synchronous CSS-grid Build Order graph.
// The redesigned graph does NO worker/ELK geometry round-trip: every semantic
// ticket card is placed by CSS grid and is in document flow the instant the
// server render arrives. The client hook only measures rendered card boxes to
// route dependency edges (a single rAF-batched pass) and owns zoom/pan/fit. So
// the budgets below guard the two costs that actually exist now: (1) the graph
// becomes semantically present quickly at every scale, and (2) a redraw
// (resize -> re-measure -> re-route edges) blocks the main thread only briefly
// and does not fan out into a self-sustaining relayout loop or leak observers.
const SIZES = [20, 50, 100]

const BUDGETS = {
  // End-to-visible: navigation start -> every semantic card present. There is no
  // async geometry to await, so this is bounded generously as an end-to-end
  // regression guard with CI-variance headroom (page load + LiveView connect +
  // synchronous grid render). A regression flips it; it is not a smoothness knob.
  endToVisibleMs: 3_000,
  // A single resize is one logical change and must coalesce to a bounded number
  // of edge-redraw passes, never a self-sustaining observer feedback loop.
  maxRedrawsPerTrigger: 2,
  redraw: {
    // Main-thread block of ONE 100-card redraw: measure all cards, route edges,
    // write one SVG path set. Bounded here with CI-variance headroom.
    maxLongTaskMs: 200,
    maxLayoutLatencyMs: 1_000
  }
}

// Instrument the page so a resize-driven edge redraw is observable as a discrete
// operation, and count how many edge-draw passes the grid hook performs. The
// hook rewrites the edge SVG (`[data-bo-grid-edges]`) once per redraw, so a
// MutationObserver on that node counts passes precisely.
async function instrumentedContext(browser) {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  await context.addInitScript(() => {
    window.__aiurGridPerf = { start: performance.now(), edgeDraws: 0 }

    const install = () => {
      const svg = document.querySelector('#fixture-build-order-graph [data-bo-grid-edges]')
      if (!svg) return false
      if (window.__aiurGridPerf.observer) window.__aiurGridPerf.observer.disconnect()
      const observer = new MutationObserver(() => { window.__aiurGridPerf.edgeDraws += 1 })
      observer.observe(svg, { childList: true })
      window.__aiurGridPerf.observer = observer
      return true
    }

    // Re-install after each LiveView patch so a remounted graph is tracked too.
    document.addEventListener('phx:update', install)
    const poll = setInterval(() => { if (install()) clearInterval(poll) }, 50)

    window.__aiurBrowserHarnessOperations = {
      // A pure resize -> re-measure -> re-route-edges cycle, isolated from
      // LiveView morphdom. The hook redraws on the next animation frame.
      redraw: () => new Promise((resolve) => {
        window.dispatchEvent(new Event('resize'))
        requestAnimationFrame(() => requestAnimationFrame(resolve))
      })
    }
  })
  return context
}

async function loadSize(page, size) {
  await page.goto(`/fixture?size=${size}`)
  await expect(page.locator('#fixture-counts')).toContainText(`nodes: ${size}`)
}

for (const size of SIZES) {
  test(`Build Order graph renders ${size} semantic cards immediately within budget`, async ({ browser }) => {
    const context = await instrumentedContext(browser)
    const page = await context.newPage()

    try {
      await openFixture(page)
      await loadSize(page, size)

      const root = page.locator('#fixture-build-order-graph')

      // Every semantic card is present in document flow — there is no fallback
      // health state or worker geometry to await.
      await expect(root.locator('[data-bo-card]')).toHaveCount(size)
      await expect(root.getByRole('heading', { name: 'Build order graph' })).toBeAttached()

      const endToVisibleMs = await page.evaluate(() => performance.now() - window.__aiurGridPerf.start)
      test.info().annotations.push({ type: `perf-${size}`, description: `endToVisible=${Math.round(endToVisibleMs)}ms` })
      expect(endToVisibleMs, `end-to-visible for ${size} cards`).toBeLessThanOrEqual(BUDGETS.endToVisibleMs)
    } finally {
      await context.close()
    }
  })
}

test('a single resize coalesces to a bounded number of edge-redraw passes', async ({ browser }) => {
  const context = await instrumentedContext(browser)
  const page = await context.newPage()

  try {
    await openFixture(page)
    await loadSize(page, 100)
    const root = page.locator('#fixture-build-order-graph')
    await expect(root.locator('[data-bo-card]')).toHaveCount(100)
    // Let the initial auto-fit + first edge draw settle.
    await page.waitForTimeout(300)

    const draws = () => page.evaluate(() => window.__aiurGridPerf.edgeDraws)
    const before = await draws()
    await page.evaluate(() => window.dispatchEvent(new Event('resize')))
    await page.waitForTimeout(100)
    const settled = await draws()
    await page.waitForTimeout(250)
    const stable = await draws()

    expect(stable, 'edge-draw count must stop growing (no feedback loop)').toBe(settled)
    expect(settled - before, 'one resize coalesces to bounded redraw passes').toBeLessThanOrEqual(BUDGETS.maxRedrawsPerTrigger)
    expect(settled - before, 'the resize must still redraw at least once').toBeGreaterThanOrEqual(1)
  } finally {
    await context.close()
  }
})

test('a 100-card redraw blocks the main thread only briefly', async ({ browser }) => {
  const context = await instrumentedContext(browser)
  const page = await context.newPage()

  try {
    await openFixture(page)
    await loadSize(page, 100)
    await expect(page.locator('#fixture-build-order-graph [data-bo-card]')).toHaveCount(100)
    await page.waitForTimeout(300)

    // A pure resize -> re-measure -> re-route cycle isolates the graph-layout
    // main-thread cost. Warm up first so samples are steady state, not JIT cold.
    const measurement = await measureBrowserWork(page, { operation: 'redraw', targetSelector: '#fixture-build-order-graph', warmups: 4, repetitions: 4 })
    const blockPerRedraw = measurement.samples.map((sample) => (sample.longTasks ?? []).reduce((total, task) => total + task, 0))
    test.info().annotations.push({ type: 'redraw-block', description: `maxBlock=${Math.round(Math.max(0, ...blockPerRedraw))}ms samples=${measurement.samples.length}` })

    for (const sample of measurement.samples) {
      const blockedMs = (sample.longTasks ?? []).reduce((total, task) => total + task, 0)
      expect(blockedMs, 'total main-thread block for one 100-card redraw stays bounded').toBeLessThanOrEqual(BUDGETS.redraw.maxLongTaskMs)
      expect(sample.layoutLatencyMs, 'redraw settles within budget').toBeLessThanOrEqual(BUDGETS.redraw.maxLayoutLatencyMs)
    }
  } finally {
    await context.close()
  }
})

test('the grid hook releases its observers across repeated unmount and remount', async ({ browser }) => {
  const context = await instrumentedContext(browser)
  const page = await context.newPage()

  try {
    await openFixture(page)
    await loadSize(page, 100)
    const root = page.locator('#fixture-build-order-graph')
    await expect(root.locator('[data-bo-card]')).toHaveCount(100)

    const cycles = 3
    for (let index = 0; index < cycles; index += 1) {
      await page.locator('#unmount-graph').click()
      await expect(page.locator('#graph-unmounted')).toBeVisible()
      await expect(root).toHaveCount(0)
      await page.locator('#remount-graph').click()
      await expect(root.locator('[data-bo-card]')).toHaveCount(100)
    }

    // After every teardown/remount cycle exactly one grid instance survives — no
    // orphaned duplicate hook or its observers accumulate in the DOM.
    await expect(page.locator('[data-bo-grid]')).toHaveCount(1)

    // The surviving grid still responds to interaction, proving its observers are
    // live (and the destroyed instances' observers were disconnected, not leaked).
    await page.locator('#fixture-build-order-graph [data-bo-grid-viewport]').focus()
    await page.keyboard.press('0')
    await page.locator('#fixture-build-order-graph [data-bo-zoom="in"]').click()
    await expect(page.locator('#fixture-build-order-graph [data-bo-zoom-level]')).toHaveText('110%')
  } finally {
    await context.close()
  }
})

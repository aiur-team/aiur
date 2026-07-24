import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

// The Build Order graph is a synchronous CSS-grid canvas drawn by the
// `BuildOrderGrid` client hook. The hook owns zoom (a CSS transform on the grid
// stage, stepped in 10% increments and clamped to 10%–160%), fit (scale the
// full grid width into the viewport), native-scroll pan, and dependency
// highlighting on hover / pin. Cards stay keyboard-openable (Enter/Space opens
// their ticket context). These specs exercise that contract against both the
// production route and the synthetic fixture graph.

async function openCatalog(page) {
  await page.goto('/build-orders')
  await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-catalog-state', 'ready')
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

async function openGraph(page, title) {
  await page.locator('.bo-catalog-link', { hasText: title }).click()
  const graph = page.locator('#selected-build-order-graph')
  await expect(graph.locator('[data-bo-card]').first()).toBeVisible()
  return graph
}

function stageTransform(graph) {
  return graph.locator('[data-bo-grid-stage]').evaluate((node) => node.style.transform || 'none')
}

test('zoom is stepped, clamped, fit-bounded, and reset by keyboard on the ready canvas', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)
    const graph = page.locator('#fixture-build-order-graph')
    await expect(graph.locator('[data-bo-card]').first()).toBeVisible()

    const readout = graph.locator('[data-bo-zoom-level]')
    const viewport = graph.locator('[data-bo-grid-viewport]')
    const zoomIn = graph.getByRole('button', { name: 'Zoom in' })
    const zoomOut = graph.getByRole('button', { name: 'Zoom out' })

    // Keyboard 0 resets to 100% so the stepping assertions start from a known scale.
    await viewport.focus()
    await page.keyboard.press('0')
    await expect(readout).toHaveText('100%')

    // Button zoom in steps by 10% and applies a matching CSS transform.
    await zoomIn.click()
    await expect(readout).toHaveText('110%')
    expect(await stageTransform(graph)).toBe('scale(1.1)')

    // Zoom in clamps at 160% and disables the control at the upper bound.
    while (!(await zoomIn.isDisabled())) await zoomIn.click()
    await expect(readout).toHaveText('160%')
    await expect(zoomIn).toBeDisabled()

    // Keyboard reset returns to 100%.
    await viewport.focus()
    await page.keyboard.press('0')
    await expect(readout).toHaveText('100%')

    // Zoom out clamps at 10% and disables the control at the lower bound.
    while (!(await zoomOut.isDisabled())) await zoomOut.click()
    await expect(readout).toHaveText('10%')
    await expect(zoomOut).toBeDisabled()

    // Fit scales the whole grid width into the viewport, never upscaling past 100%.
    await graph.getByRole('button', { name: 'Fit graph to view' }).click()
    const fitted = await stageTransform(graph)
    const fittedScale = fitted === 'none' ? 1 : Number(fitted.match(/scale\(([^)]+)\)/)[1])
    expect(fittedScale).toBeLessThanOrEqual(1)
  } finally {
    await context.close()
  }
})

test('only a modifier wheel zooms and a background drag pans the canvas', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)
    // A large graph overflows the viewport so pan has room to move.
    await page.goto('/fixture?size=100')
    await expect(page.locator('#fixture-counts')).toContainText('nodes: 100')
    const graph = page.locator('#fixture-build-order-graph')
    await expect(graph.locator('[data-bo-card]').first()).toBeVisible()

    const readout = graph.locator('[data-bo-zoom-level]')
    await graph.locator('[data-bo-grid-viewport]').focus()
    await page.keyboard.press('0')
    await expect(readout).toHaveText('100%')

    // Plain wheel scrolls the page and does not capture zoom; a modifier wheel zooms.
    const wheeled = await graph.evaluate((element) => {
      const vp = element.querySelector('[data-bo-grid-viewport]')
      const read = () => element.querySelector('[data-bo-zoom-level]').textContent
      vp.dispatchEvent(new WheelEvent('wheel', { deltaY: -120, bubbles: true, cancelable: true }))
      const afterPlain = read()
      vp.dispatchEvent(new WheelEvent('wheel', { deltaY: -120, ctrlKey: true, bubbles: true, cancelable: true }))
      return { afterPlain, afterModifier: read() }
    })
    expect(wheeled.afterPlain).toBe('100%')
    expect(wheeled.afterModifier).toBe('110%')

    // Zoom in until the scaled content overflows, then a background pointer drag
    // scrolls the viewport in place.
    const zoomIn = graph.getByRole('button', { name: 'Zoom in' })
    while (!(await zoomIn.isDisabled())) await zoomIn.click()
    const panned = await graph.evaluate((element) => {
      const vp = element.querySelector('[data-bo-grid-viewport]')
      vp.scrollLeft = 0
      vp.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 1, button: 0, clientX: 300, clientY: 200, bubbles: true }))
      vp.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, clientX: 120, clientY: 150, bubbles: true }))
      vp.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1, bubbles: true }))
      return { scrollLeft: vp.scrollLeft, overflowing: vp.scrollWidth > vp.clientWidth }
    })
    expect(panned.overflowing).toBe(true)
    expect(panned.scrollLeft).toBeGreaterThan(0)
  } finally {
    await context.close()
  }
})

test('cards stay keyboard-openable and dependency highlight pins without mutations', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials, viewport: { width: 1280, height: 900 } })
  const page = await context.newPage()

  try {
    await openCatalog(page)
    const graph = await openGraph(page, 'Release dashboard')
    await expect(graph.locator('[data-bo-card]')).toHaveCount(7)

    // Every card is focusable and carries a stable node id independent of coordinates.
    const cards = graph.locator('[data-bo-card]')
    await expect(cards.first()).toHaveAttribute('tabindex', '0')

    // Hovering a card highlights its dependency chain and marks it as the source.
    const target = graph.locator('.bo-node', { hasText: 'Readiness target' })
    await target.hover()
    await expect(target).toHaveClass(/is-hl-source/)
    await expect(graph.locator('.bo-node.is-hl-linked')).not.toHaveCount(0)

    // Clicking the blocks tag pins the highlight and locks the graph.
    await target.locator('[data-bo-pin]').click()
    await expect(graph).toHaveClass(/is-locked/)
    await expect(target).toHaveClass(/is-pinned/)
    // Clicking the tag again releases the pin.
    await target.locator('[data-bo-pin]').click()
    await expect(graph).not.toHaveClass(/is-locked/)

    // Enter on a focused openable card opens its ticket context dialog.
    await target.focus()
    await page.keyboard.press('Enter')
    const dialog = page.getByRole('dialog', { name: 'Readiness target' })
    await expect(dialog).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)

    // No interaction ever introduces a mutation: still only context navigation.
    const clicks = await page.locator('[phx-click]').evaluateAll((els) => els.map((el) => el.getAttribute('phx-click')))
    expect(clicks.every((event) => event === 'open-ticket-context')).toBe(true)
    await expect(page.locator('form')).toHaveCount(0)

    // Accessibility stays clean while a highlight is active.
    await target.hover()
    const results = await new AxeBuilder({ page }).analyze()
    expect(results.violations).toEqual([])
  } finally {
    await context.close()
  }
})

test('zoom state is isolated per selected root', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openCatalog(page)
    const graph = await openGraph(page, 'Release dashboard')
    await expect(graph).toHaveAttribute('data-bo-grid-key', '42:7')
    await graph.getByRole('button', { name: 'Zoom in' }).click()
    await expect(graph.locator('[data-bo-zoom-level]')).toHaveText('110%')

    await page.getByRole('link', { name: 'Back to all Build Orders' }).click()
    await openGraph(page, 'Stale planning lane')

    // A different root gets its own grid key and its own fresh zoom state — the
    // previous root's 110% never bleeds across.
    const next = page.locator('#selected-build-order-graph')
    await expect(next).toHaveAttribute('data-bo-grid-key', '43:8')
    await expect(next.locator('[data-bo-zoom-level]')).toHaveText('100%')
  } finally {
    await context.close()
  }
})

test('reduced motion collapses canvas transitions without disabling interaction', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials, reducedMotion: 'reduce' })
  const page = await context.newPage()

  try {
    await openFixture(page)
    const graph = page.locator('#fixture-build-order-graph')
    await expect(graph.locator('[data-bo-card]').first()).toBeVisible()

    // Reduced motion collapses the canvas transition to effectively zero. Some
    // global resets use a 1e-05s sentinel rather than 0s, so assert near-zero.
    const duration = await graph.locator('[data-bo-grid-stage]').evaluate((node) => getComputedStyle(node).transitionDuration)
    expect(parseFloat(duration)).toBeLessThan(0.05)

    // Interaction still works under reduced motion.
    await graph.locator('[data-bo-grid-viewport]').focus()
    await page.keyboard.press('0')
    await graph.getByRole('button', { name: 'Zoom in' }).click()
    await expect(graph.locator('[data-bo-zoom-level]')).toHaveText('110%')
  } finally {
    await context.close()
  }
})

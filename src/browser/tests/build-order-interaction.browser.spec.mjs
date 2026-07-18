import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

async function openCatalog(page) {
  await page.goto('/build-orders')
  await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-catalog-state', 'ready')
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

async function openGraph(page, title) {
  await page.locator('.bo-catalog-entry', { hasText: title }).getByRole('link', { name: 'Open graph' }).click()
  return page.locator('#selected-build-order-graph')
}

function scaleVar(graph) {
  return graph.locator('[data-graph-content]').evaluate((node) => node.style.getPropertyValue('--bo-graph-scale') || '1')
}

test('unit: transform policy enforces zoom bounds, grid, fit, and pan clamp', async ({ page }) => {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.goto('/build-orders')

  const result = await page.evaluate(async () => {
    const policy = await import('/aiur-dom-svg-layout/interaction-policy.js')
    return {
      clampHigh: policy.clampZoom(9),
      clampLow: policy.clampZoom(0.01),
      stepUp: Number(policy.stepZoom(1, 1).toFixed(2)),
      stepCapped: policy.stepZoom(1.5, 1),
      stepFloor: policy.stepZoom(0.5, -1),
      fitShrinks: policy.fitZoom({ width: 4000, height: 2000 }, { width: 800, height: 600 }),
      fitNoUpscale: policy.fitZoom({ width: 100, height: 100 }, { width: 800, height: 600 }),
      pan: policy.clampPan({ x: 1e6, y: -1e6 }, { width: 2000, height: 1500 }, { width: 800, height: 600 }, 1)
    }
  })

  expect(result.clampHigh).toBe(1.6)
  expect(result.clampLow).toBe(0.4)
  expect(result.stepUp).toBe(1.2)
  expect(result.stepCapped).toBe(1.6)
  expect(result.stepFloor).toBe(0.4)
  expect(result.fitShrinks).toBeLessThan(1)
  expect(result.fitShrinks).toBeGreaterThanOrEqual(0.4)
  expect(result.fitNoUpscale).toBe(1)
  expect(result.pan.x).toBeLessThan(1e6)
  expect(result.pan.y).toBeGreaterThan(-1e6)
})

test('keyboard navigation, chain highlight, selection, and Escape stay accessible without mutations', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials, viewport: { width: 1280, height: 900 } })
  const page = await context.newPage()

  try {
    await openCatalog(page)
    const graph = await openGraph(page, 'Release dashboard')
    await expect(graph.locator('[data-graph-node]')).toHaveCount(7)

    // Every card is focusable and carries a stable node id, independent of coords.
    const cards = graph.locator('[data-graph-node]')
    await expect(cards.first()).toHaveAttribute('tabindex', '0')

    // Focusing the readiness target highlights its dependency closure and dims the rest.
    const target = graph.locator('.bo-layout-card', { hasText: 'Readiness target' })
    await target.focus()
    await expect(target).toHaveClass(/is-graph-active/)
    await expect(graph.locator('.bo-layout-card.is-graph-chain')).not.toHaveCount(0)
    await expect(graph.locator('.bo-layout-card.is-graph-dimmed')).not.toHaveCount(0)

    // Arrow keys move focus in DOM (semantic) order.
    const focusedBefore = await graph.locator('[data-graph-node]:focus').getAttribute('data-graph-node')
    await page.keyboard.press('ArrowRight')
    const focusedAfter = await graph.locator('[data-graph-node]:focus').getAttribute('data-graph-node')
    expect(focusedAfter).not.toBe(focusedBefore)

    // Space pins a persistent selection with aria-current; Escape clears it.
    await target.focus()
    await page.keyboard.press(' ')
    await expect(target).toHaveClass(/is-graph-selected/)
    await expect(target).toHaveAttribute('aria-current', 'true')
    await page.keyboard.press('Escape')
    await expect(graph.locator('.bo-layout-card[aria-current="true"]')).toHaveCount(0)

    // No interaction ever introduces a mutation: still only context navigation.
    const clicks = await page.locator('[phx-click]').evaluateAll((els) => els.map((el) => el.getAttribute('phx-click')))
    expect(clicks.every((event) => event === 'open-ticket-context')).toBe(true)
    await expect(page.locator('form')).toHaveCount(0)

    // Accessibility remains clean while a selection/highlight is active.
    await target.focus()
    await page.keyboard.press(' ')
    const results = await new AxeBuilder({ page }).analyze()
    expect(results.violations).toEqual([])
  } finally {
    await context.close()
  }
})

test('bounded zoom, fit, reset, modifier-only wheel, and pointer pan operate on the ready canvas', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)
    const graph = page.locator('#fixture-build-order-graph')
    await expect(graph).toHaveClass(/is-layout-ready/)

    const readout = graph.locator('[data-graph-zoom-level]')
    const zoomIn = graph.getByRole('button', { name: 'Zoom graph in' })
    const zoomOut = graph.getByRole('button', { name: 'Zoom graph out' })

    // Button zoom in steps by 20%.
    await zoomIn.click()
    await expect(readout).toHaveText('120%')
    expect(Number(await scaleVar(graph))).toBeCloseTo(1.2, 5)

    // Zoom in clamps at 160% and disables the control at the bound.
    while (!(await zoomIn.isDisabled())) await zoomIn.click()
    await expect(readout).toHaveText('160%')
    await expect(zoomIn).toBeDisabled()

    // Reset returns to 100%.
    await graph.getByRole('button', { name: 'Reset graph zoom and pan' }).click()
    await expect(readout).toHaveText('100%')

    // Zoom out clamps at 40%.
    while (!(await zoomOut.isDisabled())) await zoomOut.click()
    await expect(readout).toHaveText('40%')
    await expect(zoomOut).toBeDisabled()

    // Fit shrinks a large graph to within the viewport (never upscales past 100%).
    await graph.getByRole('button', { name: 'Fit graph to view' }).click()
    expect(Number(await scaleVar(graph))).toBeLessThanOrEqual(1)

    // Plain wheel does not capture; modifier wheel zooms.
    await graph.getByRole('button', { name: 'Reset graph zoom and pan' }).click()
    const wheeled = await graph.evaluate((element) => {
      const vp = element.querySelector('[data-graph-viewport]')
      vp.dispatchEvent(new WheelEvent('wheel', { deltaY: -120, bubbles: true, cancelable: true }))
      const afterPlain = element.querySelector('[data-graph-content]').style.getPropertyValue('--bo-graph-scale')
      vp.dispatchEvent(new WheelEvent('wheel', { deltaY: -120, ctrlKey: true, bubbles: true, cancelable: true }))
      const afterModifier = element.querySelector('[data-graph-content]').style.getPropertyValue('--bo-graph-scale')
      return { afterPlain, afterModifier }
    })
    expect(wheeled.afterPlain).toBe('1')
    expect(Number(wheeled.afterModifier)).toBeCloseTo(1.2, 5)

    // Pointer drag on the canvas background pans.
    await graph.getByRole('button', { name: 'Reset graph zoom and pan' }).click()
    const panned = await graph.evaluate((element) => {
      const vp = element.querySelector('[data-graph-viewport]')
      vp.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 1, button: 0, clientX: 120, clientY: 120, bubbles: true }))
      window.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, clientX: 190, clientY: 160, bubbles: true }))
      window.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1, bubbles: true }))
      return element.querySelector('[data-graph-content]').style.getPropertyValue('--bo-graph-pan-x')
    })
    expect(panned).not.toBe('0px')
  } finally {
    await context.close()
  }
})

test('interaction state resets deterministically when the selected root changes', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openCatalog(page)
    const graph = await openGraph(page, 'Release dashboard')
    await expect(graph.locator('[data-graph-node]')).toHaveCount(7)
    await graph.getByRole('button', { name: 'Zoom graph in' }).click()
    await expect(graph.locator('[data-graph-zoom-level]')).toHaveText('120%')

    await page.getByRole('link', { name: 'All Build Orders' }).click()
    await openGraph(page, 'Stale planning lane')

    const next = page.locator('#selected-build-order-graph')
    await expect(next).toHaveAttribute('data-layout-root-id', '43')
    await expect(next.locator('[data-graph-zoom-level]')).toHaveText('100%')
  } finally {
    await context.close()
  }
})

test('reduced motion disables canvas transitions without disabling interaction', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials, reducedMotion: 'reduce' })
  const page = await context.newPage()

  try {
    await openFixture(page)
    const graph = page.locator('#fixture-build-order-graph')
    await expect(graph).toHaveClass(/is-layout-ready/)

    // Reduced motion collapses the canvas transition to effectively zero. Some
    // global resets use a 1e-05s sentinel rather than 0s, so assert near-zero.
    const duration = await graph.locator('[data-graph-content]').evaluate((node) => getComputedStyle(node).transitionDuration)
    expect(parseFloat(duration)).toBeLessThan(0.05)

    // Interaction still works under reduced motion.
    await graph.getByRole('button', { name: 'Zoom graph in' }).click()
    await expect(graph.locator('[data-graph-zoom-level]')).toHaveText('120%')
  } finally {
    await context.close()
  }
})

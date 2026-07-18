import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openFixture, assertNoDocumentOverflow, assertControlsRemainReachable } from './support/browser-helpers.mjs'

// BO-014 responsive acceptance. The Build Order route component must reflow at
// every supported narrow/mobile/tablet/desktop width and at 200% text zoom
// without clipping the page, hiding a fact or action, or dropping a control
// below the 44px touch target. Only the graph viewport may pan intentionally in
// two dimensions; the document itself never gains a horizontal scrollbar. These
// assertions exercise the graph route component (bo-layout / bo-graph
// namespace) in isolation, which is the surface BO-014 owns.

const VIEWPORTS = [
  { label: 'narrow-320', width: 320, height: 720 },
  { label: 'mobile-390', width: 390, height: 844 },
  { label: 'tablet-768', width: 768, height: 1024 },
  { label: 'small-desktop-960', width: 960, height: 900 },
  { label: 'desktop-1280', width: 1280, height: 900 }
]

const MIN_TOUCH_TARGET = 44

async function readyFixture(page, size) {
  await openFixture(page)
  await page.goto(`/fixture?size=${size}`)
  await expect(page.locator('#fixture-counts')).toContainText(`nodes: ${size}`)
  const root = page.locator('#fixture-build-order-graph')
  await expect(root).toHaveAttribute('data-layout-health', 'ready')
  return root
}

// Controls must never shrink below the 44px pointer target after reflow.
async function assertControlsMeetTouchTarget(page) {
  const undersized = await page.evaluate((minimum) => {
    return Array.from(document.querySelectorAll('.bo-graph-control')).flatMap((control) => {
      const rect = control.getBoundingClientRect()
      return rect.width + 0.5 < minimum || rect.height + 0.5 < minimum ? [control.textContent?.trim() || control.id] : []
    })
  }, MIN_TOUCH_TARGET)
  expect(undersized, 'every graph control keeps a 44px pointer target').toEqual([])
}

for (const { label, width, height } of VIEWPORTS) {
  test(`Build Order graph reflows a 100-member graph without page clipping at ${label}`, async ({ browser }) => {
    const context = await browser.newContext({ httpCredentials: dashboardCredentials, viewport: { width, height } })
    const page = await context.newPage()

    try {
      const root = await readyFixture(page, 100)

      // Every semantic card and the dependency summary stay in the document at
      // narrow widths — nothing is dropped to fit the viewport.
      await expect(root.locator('[data-layout-node]')).toHaveCount(100)
      await expect(root.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()

      // The page never grows a horizontal scrollbar; the graph contains its own
      // pan/scroll region. Controls stay reachable and keep their touch target.
      await assertNoDocumentOverflow(page)
      await assertControlsRemainReachable(page)
      await assertControlsMeetTouchTarget(page)
    } finally {
      await context.close()
    }
  })
}

test('Build Order graph stays unclipped and reachable at 200% text zoom on a 390px viewport', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials, viewport: { width: 390, height: 844 } })
  const page = await context.newPage()

  try {
    // Doubling the root font size scales every rem-based dimension (cards,
    // controls, headings) — a faithful proxy for 200% text zoom, which the
    // ticket requires the route to survive at narrow width.
    await context.addInitScript(() => {
      document.documentElement.style.fontSize = '200%'
    })

    const root = await readyFixture(page, 50)

    await expect(root.locator('[data-layout-node]')).toHaveCount(50)
    await expect(root.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()
    await assertNoDocumentOverflow(page)
    await assertControlsRemainReachable(page)
    await assertControlsMeetTouchTarget(page)
  } finally {
    await context.close()
  }
})

test('semantic fallback stays readable, reflowed, and unclipped at 320px', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials, viewport: { width: 320, height: 720 } })
  const page = await context.newPage()

  try {
    await openFixture(page)
    await page.goto('/fixture?size=50')
    await expect(page.locator('#fixture-counts')).toContainText('nodes: 50')

    const root = page.locator('#fixture-build-order-graph')
    await expect(root).toHaveAttribute('data-layout-health', 'ready')

    // Degrade to the semantic fallback deliberately: performance degradation must
    // change health, never graph truth. The document-flow graph must remain
    // readable and unclipped at the narrowest width.
    await page.locator('#force-layout-fallback').click()
    await expect(root).toHaveAttribute('data-layout-health', 'fallback')

    await expect(root.locator('[data-layout-node]')).toHaveCount(50)
    await expect(root.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()
    await assertNoDocumentOverflow(page)
    await assertControlsRemainReachable(page)
  } finally {
    await context.close()
  }
})

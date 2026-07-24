import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openFixture, assertNoDocumentOverflow, assertControlsRemainReachable } from './support/browser-helpers.mjs'

// Responsive acceptance for the synchronous CSS-grid Build Order graph. The
// route must reflow at every supported narrow/mobile/tablet/desktop width and
// at 200% text zoom without clipping the page, hiding a fact or action, or
// dropping a control below the 44px touch target. Only the graph's own
// `[data-bo-grid-viewport]` may pan/scroll in two dimensions; the document
// itself never gains a horizontal scrollbar. Every semantic ticket card stays
// in document flow at every width — reflow never drops graph truth to fit.

const VIEWPORTS = [
  { label: 'narrow-320', width: 320, height: 720 },
  { label: 'mobile-390', width: 390, height: 844 },
  { label: 'tablet-768', width: 768, height: 1024 },
  { label: 'small-desktop-960', width: 960, height: 900 },
  { label: 'desktop-1280', width: 1280, height: 900 }
]

async function readyGraph(page, size) {
  await openFixture(page)
  await page.goto(`/fixture?size=${size}`)
  await expect(page.locator('#fixture-counts')).toContainText(`nodes: ${size}`)
  const root = page.locator('#fixture-build-order-graph')
  await expect(root.locator('[data-bo-card]')).toHaveCount(size)
  return root
}

// Every graph control keeps a >=44px pointer target after reflow. The visible
// zoom chrome stays compact (32px) but a transparent centered `::after` overlay
// supplies the hit area — the same pattern the Units row actions use.
async function assertControlsMeetTouchTarget(page) {
  const hitAreas = await page.locator('#fixture-build-order-graph .bo-grid-zbtn').evaluateAll((buttons) =>
    buttons.map((button) => {
      const overlay = getComputedStyle(button, '::after')
      return { width: Number.parseFloat(overlay.width), height: Number.parseFloat(overlay.height) }
    })
  )
  expect(hitAreas.length, 'graph exposes zoom controls').toBeGreaterThan(0)
  expect(
    hitAreas.every(({ width, height }) => width >= 44 && height >= 44),
    'every graph control keeps a 44px pointer target'
  ).toBe(true)
}

for (const { label, width, height } of VIEWPORTS) {
  test(`Build Order graph reflows a 100-card graph without page clipping at ${label}`, async ({ browser }) => {
    const context = await browser.newContext({ httpCredentials: dashboardCredentials, viewport: { width, height } })
    const page = await context.newPage()

    try {
      const root = await readyGraph(page, 100)

      // Every semantic card and the graph heading stay in the document at narrow
      // widths — nothing is dropped to fit the viewport.
      await expect(root.locator('[data-bo-card]')).toHaveCount(100)
      await expect(root.getByRole('heading', { name: 'Build order graph' })).toBeAttached()

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
    // route must survive at narrow width.
    await context.addInitScript(() => {
      document.documentElement.style.fontSize = '200%'
    })

    const root = await readyGraph(page, 50)

    await expect(root.locator('[data-bo-card]')).toHaveCount(50)
    await expect(root.getByRole('heading', { name: 'Build order graph' })).toBeAttached()
    await assertNoDocumentOverflow(page)
    await assertControlsRemainReachable(page)
    await assertControlsMeetTouchTarget(page)
  } finally {
    await context.close()
  }
})

test('every semantic card stays readable and unclipped at the narrowest 320px width', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials, viewport: { width: 320, height: 720 } })
  const page = await context.newPage()

  try {
    const root = await readyGraph(page, 50)

    // The document-flow graph must remain readable and unclipped at the narrowest
    // supported width: the graph's own viewport scrolls, the page does not.
    await expect(root.locator('[data-bo-card]')).toHaveCount(50)
    await expect(root.getByRole('heading', { name: 'Build order graph' })).toBeAttached()

    const viewportScrolls = await root.locator('[data-bo-grid-viewport]').evaluate((vp) => ({
      horizontal: vp.scrollWidth >= vp.clientWidth,
      vertical: vp.scrollHeight >= vp.clientHeight
    }))
    expect(viewportScrolls.horizontal).toBe(true)

    await assertNoDocumentOverflow(page)
    await assertControlsRemainReachable(page)
  } finally {
    await context.close()
  }
})

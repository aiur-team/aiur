import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openFixture, assertNoDocumentOverflow } from './support/browser-helpers.mjs'

test('Build Order optimistic analytics shows measured counts and fits phone width', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()
  try {
    await openFixture(page)
    await page.goto('/optimistic-control/started')
    await page.goto('/build-orders/42')
    const tile = page.locator('.bo-analytics .an-kpi').filter({ hasText: 'Optimistic starts' })
    await expect(tile.locator('.an-kpi-val')).toHaveText('3')
    await expect(tile.locator('.an-kpi-sub')).toHaveText('1 redone · 1 discarded · 0.0h head start')
    await expect(tile).toHaveClass(/block/)
    await page.setViewportSize({ width: 390, height: 844 })
    await expect(tile).toBeVisible()
    await assertNoDocumentOverflow(page)
    await page.goto('/optimistic-control/absent')
    await page.goto('/build-orders/42')
    await expect(page.locator('.bo-analytics .an-kpis')).toBeVisible()
    await expect(page.locator('.bo-analytics')).not.toContainText('Optimistic starts')
  } finally {
    await context.close()
  }
})

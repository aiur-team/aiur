import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

const items = {
  waiting: 'Waiting', ready: 'Ready for promotion', promoted: 'Promoted',
  promoted_unauthorized: 'Promoted (unauthorized)', claimed: 'Claimed', held: 'Held',
  overridden: 'Overridden', failed_prerequisite: 'Failed prerequisite',
  completed: 'Completed', cancelled: 'Cancelled', removed: 'Removed'
}
const states = {
  empty: 'No build queues yet.', disabled: 'Build queue is disabled.',
  unsupported_tracker: 'This tracker does not support build queues.',
  store_unavailable: 'Queue store unavailable; promotion paused.',
  writes_paused: 'Queue writes paused by the GitHub budget.',
  stale: 'Queue data is stale.', unknown: 'Queue readiness unknown.'
}

for (const width of [1280, 390]) {
  test(`build queue navigation and states remain readable at ${width}px`, async ({ page }, testInfo) => {
    await page.context().setHTTPCredentials(dashboardCredentials)
    await page.setViewportSize({ width, height: 844 })
    await page.goto('/build-queue-control/running')
    await page.goto('/auth/read_only')
    await page.goto('/commands')
    const navigation = page.getByRole('link', { name: 'Build Order', exact: true })
    if (!(await navigation.isVisible())) await page.getByRole('button', { name: /navigation/i }).click()
    await navigation.click()
    await expect(page).toHaveURL(/\/build-orders$/)
    const panel = page.locator('#build-queue-panel')
    await expect(panel).toHaveAttribute('data-queue-state', 'running')
    for (const [state, label] of Object.entries(items)) {
      const row = panel.locator(`[data-item-state="${state}"]`)
      await expect(row.locator('.badge')).toHaveText(label)
      await expect(row.locator('.badge')).toBeVisible()
      for (const cell of [row.locator('.badge'), row.locator('td').nth(1)]) {
        expect(await cell.evaluate((element) => {
          const range = document.createRange()
          range.selectNodeContents(element)
          return range.getClientRects().length
        })).toBe(1)
      }
    }
    await expect(panel).toContainText('12s ago')
    await expect(panel).toContainText('3 open downstream · priority 2')
    await expect(panel).toContainText('#2999 · Waiting for completion')
    await expect(panel.locator('[data-queue-attention="open"]')).toContainText('operator attention')
    await expect(panel.locator('[data-queue-attention="resolved"]')).toContainText('prerequisite recovered')
    await expect(panel.locator('button, input, form')).toHaveCount(0)
    await assertNoDocumentOverflow(page)
    await page.screenshot({ fullPage: true, path: testInfo.outputPath(`build-queue-${width}.png`) })
    await testInfo.attach(`Build queue ${width}px`, { path: testInfo.outputPath(`build-queue-${width}.png`), contentType: 'image/png' })

    for (const [state, message] of Object.entries(states)) {
      await page.goto(`/build-queue-control/${state}`)
      await expect(panel).toHaveAttribute('data-queue-state', state)
      await expect(panel.getByRole('status')).toContainText(message)
      if (['stale', 'unknown'].includes(state)) {
        await expect(panel.locator('[data-readiness-dimmed]')).toHaveCount(11)
        await expect(panel.locator('[data-item-state="ready"] .badge')).toHaveText('Unknown')
      }
      await assertNoDocumentOverflow(page)
    }
  })
}

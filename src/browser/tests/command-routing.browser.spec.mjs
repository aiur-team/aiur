import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow, openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

for (const width of [390, 1280]) {
  test(`Command routing filters remain usable at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 })
    await openFixture(page)
    await page.context().setHTTPCredentials(dashboardCredentials)
    await page.goto('/commands')
    await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)

    for (const [route, label] of [
      ['needs_you', 'Needs you'],
      ['with_executor', 'With Executor'],
      ['from_executor', 'From Executor'],
      ['resolved', 'Resolved']
    ]) {
      const button = page.locator(`button[data-count-label="${label}"]`)
      await button.click()
      await expect(page).toHaveURL(new RegExp(`route=${route}`))
      await expect(button).toHaveAttribute('aria-pressed', 'true')
      await assertNoDocumentOverflow(page)
    }
    await page.screenshot({ path: testInfo.outputPath(`command-routing-${width}.png`), fullPage: true })
  })
}

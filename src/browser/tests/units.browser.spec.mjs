import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { nextPaint } from './support/measurements.mjs'

async function openUnits(page) {
  await page.goto('/auth/read_only')
  await page.goto('/units')
  await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

test('Units keeps complete semantic rows, named actions, and 44px targets across required widths and zoom', async ({ browser }) => {
  test.setTimeout(60_000)

  for (const width of [320, 390, 768, 960, 1440]) {
    const mobile = width <= 390
    const context = await browser.newContext({
      viewport: { width, height: 900 },
      hasTouch: mobile,
      isMobile: mobile,
      reducedMotion: 'reduce'
    })
    const page = await context.newPage()

    try {
      await openUnits(page)

      const rows = page.getByRole('row').filter({ has: page.getByRole('button', { name: 'Inspect ticket' }) })
      const first = rows.first()
      const unknownProgress = rows.nth(1).getByText('Progress unavailable')

      await expect(rows).toHaveCount(2)
      await expect(first).toContainText('its-everdred/aiur #1110')
      await expect(first).toContainText('Responsive Units interface')
      await expect(first).toContainText('gpt-5.6-terra')
      await expect(first).toContainText('Lane L2')
      await expect(first).toContainText('Branch · feature pushed')
      await expect(first.getByRole('progressbar', { name: 'Unit progress' })).toHaveAttribute('aria-valuenow', '50')
      await expect(unknownProgress).not.toHaveAttribute('aria-valuenow')
      // When no conversation handle exists the action is omitted entirely, not shown as a disabled placeholder.
      await expect(first.getByText('Conversation unavailable')).toHaveCount(0)
      await expect(first.getByRole('button', { name: /Read conversation/ })).toHaveCount(0)
      await expect(first.getByRole('link', { name: /Open Commands/ })).toBeVisible()
      await expect(first.getByRole('link', { name: /Open Commands/ })).toHaveAttribute('href', '/decisions?ticket=1110')
      await expect(first.getByRole('link', { name: 'GitHub' })).toBeVisible()
      await expect(first.getByRole('button', { name: 'Agent log' })).toBeVisible()

      expect(await first.getAttribute('phx-click')).toBeNull()
      await expect(page.locator('#units-status')).toHaveCount(1)
      await expect(page.locator('#units-status')).toHaveAttribute('aria-atomic', 'true')

      const actionSizes = await first.locator('.units-action').evaluateAll((actions) =>
        actions.map((action) => {
          const box = action.getBoundingClientRect()
          return { width: box.width, height: box.height }
        })
      )
      expect(actionSizes.every(({ width: actionWidth, height }) => actionWidth >= 44 && height >= 44)).toBe(true)

      if (mobile) {
        await page.getByRole('button', { name: 'None' }).tap()
        const resetSize = await page.getByRole('button', { name: 'Reset Units filters' }).evaluate((button) => {
          const box = button.getBoundingClientRect()
          return { width: box.width, height: box.height }
        })
        expect(resetSize.width).toBeGreaterThanOrEqual(44)
        expect(resetSize.height).toBeGreaterThanOrEqual(44)
        await page.getByRole('button', { name: 'Reset Units filters' }).tap()
      }

      const rowDisplay = await first.evaluate((row) => getComputedStyle(row).display)
      expect(rowDisplay).toBe(width === 1440 ? 'table-row' : 'grid')
      await expect.poll(() => page.evaluate(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)).toBe(true)

      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
      await nextPaint(page)
      await assertNoDocumentOverflow(page)

      if (width === 390 || width === 1440) {
        const accessibility = await new AxeBuilder({ page }).analyze()
        expect(accessibility.violations).toEqual([])
      }

      if (mobile) {
        await first.getByRole('button', { name: 'Inspect ticket' }).tap()
        await expect(page.getByRole('dialog', { name: 'Responsive Units interface' })).toBeVisible()
        await page.getByRole('button', { name: 'Close' }).tap()
      }
    } finally {
      await context.close()
    }
  }
})

test('Units URL history restores independent conditions and copied links', async ({ page, context }) => {
  await openUnits(page)

  await page.getByRole('button', { name: 'All' }).click()
  await expect(page).toHaveURL(/\/units\?v=1&scope=all$/)
  await expect(page.getByText('Finished accessibility evidence')).toBeVisible()

  await page.getByRole('button', { name: /Alert 1/ }).click()
  await expect(page).toHaveURL(/conditions=alert$/)
  await expect(page.getByText('Paused provider follow-up')).toBeVisible()
  await expect(page.getByText('Responsive Units interface')).toHaveCount(0)

  const copiedUrl = page.url()
  const copied = await context.newPage()
  await copied.goto(copiedUrl)
  await expect(copied.getByRole('button', { name: /Alert 1/ })).toHaveAttribute('aria-pressed', 'true')
  await expect(copied.getByText('Paused provider follow-up')).toBeVisible()
  await copied.close()

  await page.goBack()
  await expect(page.getByRole('button', { name: 'All' })).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByText('Finished accessibility evidence')).toBeVisible()

  await page.goBack()
  await expect(page.getByRole('button', { name: 'Live' })).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByText('Finished accessibility evidence')).toHaveCount(0)

  await page.getByRole('button', { name: 'None' }).click()
  await expect(page.getByRole('button', { name: 'Reset Units filters' })).toBeVisible()
  await page.getByRole('button', { name: 'Reset Units filters' }).click()
  await expect(page).toHaveURL(/\/units\?v=1$/)
  await expect(page.getByText('Responsive Units interface')).toBeVisible()
})

test('Units preserves focused controls on stable updates and restores dialog focus with a safe fallback', async ({ page }) => {
  await openUnits(page)

  const initialInspect = page.getByRole('button', { name: 'Inspect ticket' }).first()
  const inspectId = await initialInspect.getAttribute('id')
  const inspect = page.locator(`#${inspectId}`)
  await inspect.focus()
  await page.keyboard.press('Enter')

  let dialog = page.getByRole('dialog', { name: 'Responsive Units interface' })
  await expect(dialog).toBeVisible()
  await expect(dialog.getByRole('heading', { name: 'Responsive Units interface' })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(dialog).toHaveCount(0)
  await expect(inspect).toBeFocused()

  const announcementBefore = await page.locator('#units-status').textContent()
  await page.locator('#same-identity-update').evaluate((button) => button.click())
  await expect(inspect).toBeFocused()
  await expect(page.getByText('Responsive Units interface · updated')).toBeVisible()
  await expect(page.locator('#units-status')).not.toHaveText(announcementBefore)
  await expect(page.locator('#units-status')).toContainText(/Catalog update [a-f0-9]{10}/)
  await expect(page.locator('[role="status"][aria-live="polite"]')).toHaveCount(1)

  await page.keyboard.press('Enter')
  dialog = page.getByRole('dialog', { name: 'Responsive Units interface · updated' })
  await expect(dialog).toBeVisible()

  await page.locator('#remove-selected-unit').evaluate((button) => button.click())
  await expect(inspect).toHaveCount(0)
  await page.keyboard.press('Escape')
  await expect(dialog).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Units' })).toBeFocused()
})

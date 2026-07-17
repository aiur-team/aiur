import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { nextPaint } from './support/measurements.mjs'

async function openTicketContext(page) {
  await page.goto('/auth/read_only')
  await page.goto('/ticket-context')
  await expect(page.locator('[data-ticket-context-fixture="true"]')).toBeVisible()
  await expect(page.getByRole('dialog', { name: 'Configured ticket' })).toBeVisible()
}

test('ticket context keeps its semantic content and keyboard lifecycle accessible at responsive sizes', async ({ browser }) => {
  for (const { width, isMobile, forcedColors } of [
    { width: 320, isMobile: true, forcedColors: 'active' },
    { width: 768, isMobile: false, forcedColors: 'none' },
    { width: 1440, isMobile: false, forcedColors: 'none' }
  ]) {
    const context = await browser.newContext({
      viewport: { width, height: 844 },
      hasTouch: isMobile,
      isMobile,
      reducedMotion: 'reduce',
      forcedColors
    })
    const page = await context.newPage()

    try {
      await openTicketContext(page)

      const dialog = page.getByRole('dialog', { name: 'Configured ticket' })
      const heading = dialog.getByRole('heading', { name: 'Configured ticket' })
      const close = dialog.getByRole('button', { name: 'Close' })
      const chat = dialog.getByRole('link', { name: 'Chat' })

      await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
      await expect(heading).toBeFocused()
      await expect(dialog.getByRole('status')).toContainText('Ticket detail is current.')
      await expect(dialog.getByRole('list')).toContainText('Progress updated')
      await expect(dialog.getByText('Pull request', { exact: true })).toHaveAttribute('aria-disabled', 'true')
      await expect(dialog.getByText('Pull request has not been opened.')).toBeVisible()
      await expect.poll(() => page.evaluate(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)).toBe(true)
      await expect.poll(() => page.evaluate(() => getComputedStyle(document.querySelector('.ticket-context-panel')).transitionProperty)).toBe('none')
      await expect.poll(() => page.evaluate(() => window.matchMedia('(forced-colors: active)').matches)).toBe(forcedColors === 'active')

      await page.evaluate(() => { document.documentElement.dataset.theme = 'light' })
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')

      await page.keyboard.press('Shift+Tab')
      await expect(chat).toBeFocused()
      await page.keyboard.press('Tab')
      await expect(close).toBeFocused()

      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
      await nextPaint(page)
      await assertNoDocumentOverflow(page)

      const accessibility = await new AxeBuilder({ page }).analyze()
      expect(accessibility.violations).toEqual([])

      if (isMobile) {
        await close.tap()
      } else {
        await page.keyboard.press('Escape')
      }

      await expect(page.getByRole('dialog')).toHaveCount(0)
      await expect(page.locator('#ticket-context-closed')).toHaveText('Ticket context closed.')
    } finally {
      await context.close()
    }
  }
})

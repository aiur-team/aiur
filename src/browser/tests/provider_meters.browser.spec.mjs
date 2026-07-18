import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { nextPaint } from './support/measurements.mjs'

async function openProviderMeters(page) {
  await page.goto('/auth/read_only')
  await page.goto('/provider-meters')
  await expect(page.locator('[data-provider-meters-fixture="true"]')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

test('Provider meters expose semantic meters, machine-readable resets, and stay accessible across widths and zoom', async ({ browser }) => {
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
      await openProviderMeters(page)

      const codex = page.getByRole('article', { name: 'Codex' })
      const claude = page.getByRole('article', { name: 'Claude' })
      await expect(codex).toBeVisible()
      await expect(claude).toBeVisible()

      // The supported window exposes an exact semantic meter; the unsupported
      // window and the unknown Claude account carry no implied value.
      await expect(codex.getByRole('progressbar', { name: 'Primary usage' })).toHaveAttribute('aria-valuenow', '40')
      await expect(codex).toContainText('Not supported')
      await expect(claude).toContainText('Account identity unknown')
      await expect(claude.getByRole('progressbar')).toHaveCount(0)

      // Reset time is machine-readable and human-visible.
      await expect(codex.locator('time')).toHaveAttribute('datetime', '2026-07-18T12:00:00Z')

      // A single polite, atomic live region drives announcements.
      await expect(page.locator('#provider-meters-status')).toHaveAttribute('aria-live', 'polite')
      await expect(page.locator('#provider-meters-status')).toHaveAttribute('aria-atomic', 'true')

      await expect.poll(() => page.evaluate(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)).toBe(true)

      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
      await nextPaint(page)
      await assertNoDocumentOverflow(page)

      if (width === 390 || width === 1440) {
        const accessibility = await new AxeBuilder({ page }).analyze()
        expect(accessibility.violations).toEqual([])
      }
    } finally {
      await context.close()
    }
  }
})

test('A locked connection shows the content-free locked state with no protected meter values', async ({ page }) => {
  await openProviderMeters(page)

  await page.locator('#lock-provider-meters').click()

  const status = page.getByRole('status').filter({ hasText: 'locked' }).first()
  await expect(status).toBeVisible()
  await expect(page.getByRole('article', { name: 'Codex' })).toHaveCount(0)
  await expect(page.getByRole('article', { name: 'Claude' })).toHaveCount(0)
  await expect(page.getByRole('progressbar')).toHaveCount(0)
  await expect(page.locator('[data-provider-meters-fixture="true"] dt', { hasText: 'Plan' })).toHaveCount(0)
  await expect(page.locator('[data-provider-meters-fixture="true"]')).not.toContainText('fixture-codex-generation')

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations).toEqual([])
})

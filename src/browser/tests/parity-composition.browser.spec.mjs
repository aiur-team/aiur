import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertFixtureAccessDenied, assertNoDocumentOverflow, openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

// DASH-033 composed parity proof. The per-region specs (route-shell, units,
// provider_meters, ticket-context, build-order-*) each prove one destination in
// isolation. This spec proves the *composition*: a single authenticated session
// walks every named existing-page destination in sequence and asserts each named
// region survives ("nothing silently disappears"), that the protected financial
// region locks content-free without crashing navigation, and that the composed
// shell survives an unauthenticated rejection and a LiveView reconnect. It reuses
// the existing synthetic fixtures and invents no operational data.

const composedViewports = [
  { label: 'mobile 390px', width: 390, isMobile: true },
  { label: 'desktop 1440px', width: 1440, isMobile: false }
]

for (const { label, width, isMobile } of composedViewports) {
  test(`composed authenticated session preserves every named region (${label})`, async ({ browser }) => {
    const context = await browser.newContext({
      viewport: { width, height: 844 },
      hasTouch: isMobile,
      isMobile,
      reducedMotion: 'reduce'
    })
    const page = await context.newPage()

    try {
      await openFixture(page, 'read_only')
      // The Build Order destination is served by the real forwarded router under
      // dashboard_basic_auth, so the composed walk carries HTTP credentials too.
      await page.context().setHTTPCredentials(dashboardCredentials)

      // Shell: Units is the default route; live navigation to Commands and Build
      // Order stays URL-backed with a persistent, accessible navigation region.
      await page.goto('/')
      await expect(page.locator('#route-title')).toHaveText('Units')
      await expect(page.getByRole('link', { name: 'Build Order' })).toHaveAttribute('href', '/build-orders')
      await assertNoDocumentOverflow(page)

      const commands = page.getByRole('link', { name: 'Commands' })
      if (isMobile) {
        await commands.tap()
      } else {
        await commands.click()
      }
      await expect(page).toHaveURL(/\/commands$/)
      await expect(page.locator('#route-title')).toHaveText('Commands')
      await expect(page.getByRole('link', { name: 'Commands' })).toHaveAttribute('aria-current', 'page')
      await assertNoDocumentOverflow(page)

      await page.getByRole('link', { name: 'Build Order' }).click()
      await expect(page).toHaveURL(/\/build-orders$/)
      await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-catalog-state', 'ready')
      await assertNoDocumentOverflow(page)

      await page.getByRole('link', { name: 'Units' }).click()
      await expect(page).toHaveURL(/\/$/)
      await expect(page.locator('#route-title')).toHaveText('Units')

      // Standalone region fixtures are not linked from the shell nav; visit each
      // directly within the same authenticated session and assert its landmark
      // plus its accessible live-status region survives.
      await page.goto('/units')
      await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
      await expect(page.locator('#units-status')).toHaveAttribute('aria-atomic', 'true')
      await assertNoDocumentOverflow(page)

      await page.goto('/provider-meters')
      await expect(page.locator('[data-provider-meters-fixture="true"]')).toBeVisible()
      await expect(page.locator('#provider-meters-status')).toHaveAttribute('aria-live', 'polite')
      await expect(page.getByRole('progressbar').first()).toBeVisible()
      await assertNoDocumentOverflow(page)

      await page.goto('/ticket-context')
      await expect(page.locator('[data-ticket-context-fixture="true"]')).toBeVisible()
      await assertNoDocumentOverflow(page)

      const accessibility = await new AxeBuilder({ page }).analyze()
      expect(accessibility.violations).toEqual([])
    } finally {
      await context.close()
    }
  })
}

test('a locked financial region degrades content-free without crashing composed navigation', async ({ page }) => {
  await openFixture(page, 'read_only')

  await page.goto('/provider-meters')
  await expect(page.locator('[data-provider-meters-fixture="true"]')).toBeVisible()
  await expect(page.getByRole('progressbar').first()).toBeVisible()

  await page.locator('#lock-provider-meters').click()
  await expect(page.getByRole('status').filter({ hasText: 'locked' }).first()).toBeVisible()
  await expect(page.getByRole('progressbar')).toHaveCount(0)
  await expect(page.locator('[data-provider-meters-fixture="true"] dt', { hasText: 'Plan' })).toHaveCount(0)
  await expect(page.locator('[data-provider-meters-fixture="true"]')).not.toContainText('fixture-codex-generation')

  // The bounded lock degrades only its own region: the rest of the composed
  // shell stays navigable and safe nonfinancial facts remain visible.
  await page.goto('/')
  await expect(page.locator('#route-title')).toHaveText('Units')
  await assertNoDocumentOverflow(page)

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations).toEqual([])
})

test('composed shell rejects unauthenticated access and survives a LiveView reconnect', async ({ page }) => {
  await assertFixtureAccessDenied(page)

  await openFixture(page, 'read_only')
  await page.goto('/')
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)

  await page.evaluate(() => window.liveSocket.disconnect())
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(false)
  await page.evaluate(() => window.liveSocket.connect())
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)

  await expect(page.locator('#route-title')).toHaveText('Units')
  await expect(page.getByRole('link', { name: 'Commands' })).toBeVisible()
  await assertNoDocumentOverflow(page)
})

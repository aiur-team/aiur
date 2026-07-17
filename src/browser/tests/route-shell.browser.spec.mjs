import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow, openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { nextPaint } from './support/measurements.mjs'

test('route shell keeps navigation URL-backed, accessible, and unclipped across responsive widths', async ({ browser }) => {
  for (const { width, isMobile } of [
    { width: 320, isMobile: true },
    { width: 390, isMobile: true },
    { width: 768, isMobile: false },
    { width: 960, isMobile: false },
    { width: 1440, isMobile: false }
  ]) {
    const context = await browser.newContext({
      viewport: { width, height: 844 },
      hasTouch: isMobile,
      isMobile,
      reducedMotion: 'reduce'
    })
    const page = await context.newPage()

    try {
      await openFixture(page)
      await page.goto('/?analytics=unavailable')
      await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
      await expect(page.getByRole('link', { name: 'Analytics' })).toHaveCount(0)
      await expect(page.locator('.shell-nav-item.is-unavailable', { hasText: 'Analytics' }).first()).toHaveAttribute('aria-disabled', 'true')

      await page.goto('/')

      await expect(page.getByRole('heading', { name: 'Units' })).toBeVisible()
      await expect(page.getByRole('link', { name: 'Commands' })).not.toHaveAttribute('aria-current')
      await expect(page.getByRole('link', { name: 'Build Order' })).toHaveAttribute('href', '/build-orders')
      await expect(page.getByRole('link', { name: 'Analytics' })).toHaveAttribute('href', '/analytics')
      await assertNoDocumentOverflow(page)

      const commands = page.getByRole('link', { name: 'Commands' })

      if (isMobile) {
        await commands.tap()
      } else {
        await commands.press('Enter')
      }
      await expect(page).toHaveURL(/\/decisions$/)
      await expect(page.getByRole('heading', { name: 'Commands' })).toBeVisible()
      await expect(page.getByRole('link', { name: 'Commands' })).toHaveAttribute('aria-current', 'page')

      await page.goBack()
      await expect(page).toHaveURL(/\/$/)
      await expect(page.getByRole('heading', { name: 'Units' })).toBeVisible()

      await page.goForward()
      await expect(page).toHaveURL(/\/decisions$/)
      await expect(page.getByRole('heading', { name: 'Commands' })).toBeVisible()

      await page.goto('/decisions/decision-123')
      await expect(page).toHaveURL(/\/decisions\/decision-123$/)
      await expect(page.getByRole('heading', { name: 'Commands' })).toBeVisible()
      await expect(page.getByRole('link', { name: 'Commands' })).toHaveAttribute('aria-current', 'page')

      await context.setHTTPCredentials(dashboardCredentials)
      const buildOrder = page.getByRole('link', { name: 'Build Order' })

      if (isMobile) {
        await buildOrder.tap()
      } else {
        await buildOrder.press('Enter')
      }

      await expect(page).toHaveURL(/\/build-orders$/)
      await expect(page.getByRole('heading', { name: 'Build Order', exact: true })).toBeVisible()
      await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-catalog-state', 'ready')
      await expect(page.getByRole('link', { name: 'Build Order' })).toHaveAttribute('aria-current', 'page')

      const units = page.getByRole('link', { name: 'Units' })

      if (isMobile) {
        await units.tap()
      } else {
        await units.press('Enter')
      }

      await expect(page).toHaveURL(/\/$/)
      await expect(page.getByRole('heading', { name: 'Units' })).toBeVisible()
      await expect(page.locator('#route-shell-action')).toBeVisible()

      await page.getByRole('button', { name: 'Toggle color theme' }).click()
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')

      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
      await nextPaint(page)
      await assertNoDocumentOverflow(page)
      await expect(page.locator('#route-shell-action')).toBeVisible()

      if (width < 960) {
        const reservedSpace = await page.evaluate(() => {
          const app = document.querySelector('.app-shell')
          const navigation = document.querySelector('.shell-nav-mobile')
          const rect = navigation.getBoundingClientRect()

          return {
            navigation: rect.height + window.innerHeight - rect.bottom,
            padding: Number.parseFloat(getComputedStyle(app).paddingBlockEnd)
          }
        })

        expect(reservedSpace.padding).toBeGreaterThanOrEqual(reservedSpace.navigation)
      } else {
        const sidebar = page.locator('.shell-sidebar')
        const initialTop = (await sidebar.boundingBox()).y

        await page.evaluate(() => {
          const spacer = document.createElement('div')
          spacer.style.height = '1200px'
          spacer.setAttribute('aria-hidden', 'true')
          document.querySelector('.shell-content').append(spacer)
          window.scrollTo(0, 600)
        })
        await nextPaint(page)

        expect((await sidebar.boundingBox()).y).toBeCloseTo(initialTop, 0)
      }

      const accessibility = await new AxeBuilder({ page }).analyze()
      expect(accessibility.violations).toEqual([])
    } finally {
      await context.close()
    }
  }
})

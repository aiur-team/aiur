import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow, openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { nextPaint } from './support/measurements.mjs'

test('dashboard page loads return no HTTP 404 responses', async ({ page }) => {
  const notFound = []
  const consoleErrors = []
  const pageErrors = []

  page.on('response', (response) => {
    if (response.status() === 404) notFound.push(response.url())
  })
  page.on('console', (message) => {
    if (message.type() === 'error') consoleErrors.push(message.text())
  })
  page.on('pageerror', (error) => pageErrors.push(error.message))

  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)

  for (const path of ['/', '/units', '/decisions', '/build-orders', '/analytics']) {
    await page.goto(path)
    await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  }

  expect(notFound).toEqual([])
  expect(consoleErrors).toEqual([])
  expect(pageErrors).toEqual([])
})

test('Build Order navigation returns to the production Units route', async ({ page }) => {
  await openFixture(page)
  await page.goto('/')
  await page.context().setHTTPCredentials(dashboardCredentials)

  await page.getByRole('link', { name: 'Build Order' }).click()
  await expect(page).toHaveURL(/\/build-orders$/)
  await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-catalog-state', 'ready')

  await page.getByRole('link', { name: 'Units' }).click()
  await expect(page).toHaveURL(/\/$/)
  await expect(page.locator('#route-title')).toHaveText('Units')
  await expect(page.locator('.units-card')).toBeVisible()
  await expect(page.locator('#route-shell-action')).toHaveCount(0)
})

const routeShellViewports = [
  { width: 320, isMobile: true },
  { width: 390, isMobile: true },
  { width: 768, isMobile: false },
  { width: 960, isMobile: false },
  { width: 1440, isMobile: false }
]

for (const { width, isMobile } of routeShellViewports) {
  test(`route shell keeps navigation URL-backed, accessible, and unclipped at ${width}px`, async ({ browser }) => {
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
      await expect(page.getByRole('link', { name: 'Analytics' })).toHaveAttribute('href', '/analytics')

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
      await expect(page.locator('#route-shell-action')).toBeVisible()

      // The theme + nav toggles live in the desktop sidebar, which the compact
      // layout hides below 960px in favour of the fixed bottom nav. Only
      // exercise the sidebar theme toggle where the sidebar is present.
      if (width >= 960) {
        await page.getByRole('button', { name: 'Toggle color theme' }).click()
        await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
      }

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
        const topbar = page.locator('.topbar')
        const initialTop = (await topbar.boundingBox()).y

        await page.evaluate(() => {
          const spacer = document.createElement('div')
          spacer.style.height = '1200px'
          spacer.setAttribute('aria-hidden', 'true')
          document.querySelector('.shell-content').append(spacer)
          window.scrollTo(0, 600)
        })
        await nextPaint(page)

        expect((await topbar.boundingBox()).y).toBeCloseTo(initialTop, 0)
      }

      const accessibility = await new AxeBuilder({ page }).analyze()
      expect(accessibility.violations).toEqual([])
    } finally {
      await context.close()
    }
  })
}

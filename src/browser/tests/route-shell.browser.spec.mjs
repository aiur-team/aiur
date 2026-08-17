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

  for (const path of ['/', '/units', '/commands', '/build-orders', '/analytics']) {
    await page.goto(path)
    await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  }

  expect(notFound).toEqual([])
  expect(consoleErrors).toEqual([])
  expect(pageErrors).toEqual([])
})

test('legacy Commands URLs redirect permanently to the canonical route', async ({ page }) => {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)

  const response = await page.goto('/decisions/decision-123?filter=blocking')
  const redirectedFrom = response?.request().redirectedFrom()

  expect((await redirectedFrom?.response())?.status()).toBe(301)
  await expect(page).toHaveURL(/\/commands\/decision-123\?filter=blocking$/)
  await expect(page.getByRole('heading', { name: 'Commands' })).toBeVisible()
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

// The sidebar runs hard against the window's left edge, so its states are
// square there and rounded only on the right. The mobile pill is a floating
// island and keeps rounding all round — the contrast is the whole point, so
// both halves are asserted.
test('the sidebar state squares its window-edge corners while the mobile pill stays fully rounded', async ({ browser }) => {
  const desktop = await browser.newContext({ viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce' })
  const desktopPage = await desktop.newPage()

  try {
    await openFixture(desktopPage)
    await desktopPage.goto('/')

    const corners = await desktopPage.locator('.shell-nav-sidebar .shell-nav-item.is-active').evaluate((item) => {
      const style = getComputedStyle(item)
      return {
        topLeft: style.borderTopLeftRadius,
        bottomLeft: style.borderBottomLeftRadius,
        topRight: style.borderTopRightRadius,
        bottomRight: style.borderBottomRightRadius
      }
    })

    expect(corners.topLeft).toBe('0px')
    expect(corners.bottomLeft).toBe('0px')
    expect(corners.topRight).not.toBe('0px')
    expect(corners.bottomRight).not.toBe('0px')
  } finally {
    await desktop.close()
  }

  const mobile = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, reducedMotion: 'reduce' })
  const mobilePage = await mobile.newPage()

  try {
    await openFixture(mobilePage)
    await mobilePage.goto('/')

    const radii = await mobilePage.locator('.shell-nav-mobile .shell-nav-item.is-active').evaluate((item) => {
      const style = getComputedStyle(item)
      return [style.borderTopLeftRadius, style.borderBottomLeftRadius, style.borderTopRightRadius, style.borderBottomRightRadius]
    })

    expect(radii.every((radius) => radius !== '0px')).toBe(true)
  } finally {
    await mobile.close()
  }
})

// The collapsed sidebar keeps a bare rail for exactly one reason: the control
// that reopens the nav has to stay on screen. Nothing else proves that.
test('the collapse toggle stays reachable while the nav is collapsed', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce' })
  const page = await context.newPage()

  try {
    await openFixture(page)
    await page.goto('/')

    const shell = page.locator('.dashboard-shell')
    const toggle = page.locator('#nav-toggle')
    await expect(page.locator('.shell-nav-sidebar')).toBeVisible()

    await toggle.click()
    await expect(shell).toHaveAttribute('data-nav-collapsed', 'true')
    await expect(page.locator('.shell-nav-sidebar')).not.toBeVisible()

    // Still on screen, and not pushed off the left edge by the collapsed rail.
    await expect(toggle).toBeVisible()
    const box = await toggle.boundingBox()
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(1440)

    await toggle.click()
    await expect(shell).toHaveAttribute('data-nav-collapsed', 'false')
    await expect(page.locator('.shell-nav-sidebar')).toBeVisible()
  } finally {
    await context.close()
  }
})

// The shell runs the full window width with the sidebar hard left, and the
// content column mirrors the sidebar rail so the page lands on the window's
// midpoint. The mirror only fits once the window is wide enough for
// rail + measure + rail, so the narrower case is pinned too: it must still be
// left-biased rather than snapping to centre.
test('wide windows centre the page on the window, not on the space beside the sidebar', async ({ browser }) => {
  const contentOffset = (page) =>
    page.locator('.shell-content').evaluate((content) => {
      const rect = content.getBoundingClientRect()
      return (rect.left + rect.right) / 2 - window.innerWidth / 2
    })

  for (const width of [1920, 2560]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, reducedMotion: 'reduce' })
    const page = await context.newPage()

    try {
      await openFixture(page)
      await page.goto('/')

      expect(Math.abs(await contentOffset(page))).toBeLessThan(20)
      await assertNoDocumentOverflow(page)

      // Collapsing narrows the rail, so the mirror has to follow it.
      await page.locator('#nav-toggle').click()
      await expect(page.locator('.dashboard-shell')).toHaveAttribute('data-nav-collapsed', 'true')
      expect(Math.abs(await contentOffset(page))).toBeLessThan(20)
      await assertNoDocumentOverflow(page)
    } finally {
      await context.close()
    }
  }

  // Too narrow to mirror the full rail: the page is still pushed right of the
  // window's midpoint rather than jumping straight to centre.
  const narrow = await browser.newContext({ viewport: { width: 1280, height: 900 }, reducedMotion: 'reduce' })
  const narrowPage = await narrow.newPage()

  try {
    await openFixture(narrowPage)
    await narrowPage.goto('/')

    expect(await contentOffset(narrowPage)).toBeGreaterThan(20)
    await assertNoDocumentOverflow(narrowPage)
  } finally {
    await narrow.close()
  }
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
      await expect(page).toHaveURL(/\/commands$/)
      await expect(page.getByRole('heading', { name: 'Commands' })).toBeVisible()
      await expect(page.getByRole('link', { name: 'Commands' })).toHaveAttribute('aria-current', 'page')

      await page.goBack()
      await expect(page).toHaveURL(/\/$/)
      await expect(page.getByRole('heading', { name: 'Units' })).toBeVisible()

      await page.goForward()
      await expect(page).toHaveURL(/\/commands$/)
      await expect(page.getByRole('heading', { name: 'Commands' })).toBeVisible()

      await page.goto('/commands/decision-123')
      await expect(page).toHaveURL(/\/commands\/decision-123$/)
      await expect(page.getByRole('heading', { name: 'Commands' })).toBeVisible()
      await expect(page.getByRole('link', { name: 'Commands' })).toHaveAttribute('aria-current', 'page')
      await expect(page.locator('#route-shell-action')).toBeVisible()

      // The theme toggle lives in the topbar at every resolution; the nav
      // toggle lives in the desktop sidebar, which the compact layout hides
      // below 960px in favour of the fixed bottom nav.
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

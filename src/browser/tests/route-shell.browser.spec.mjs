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

  for (const path of ['/', '/units', '/commands', '/build-orders', '/analytics', '/experiments']) {
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

test('navigation keeps its labels reachable after collapse and expansion', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await openFixture(page)
  await page.goto('/')
  const drag = page.locator('#ax-drag')
  await expect(page.locator('.sidenav-nav')).toBeVisible()
  await drag.click()
  await expect(drag).toHaveAttribute('data-nav-collapsed', 'true')
  expect(await page.locator('.snav-label').first().evaluate(node => getComputedStyle(node).clipPath)).toBe('inset(50%)')
  await expect(page.getByRole('link', { name: 'Units', exact: true })).toBeVisible()
  await expect(drag).toBeInViewport()
  await expect(page.locator('.sidenav-nav')).toBeVisible()
  await drag.click()
  await expect(drag).toHaveAttribute('data-nav-collapsed', 'false')
  await expect(page.locator('.snav-label').first()).toBeVisible()
})

test('active navigation follows the design corners on desktop and phone', async ({ page }) => {
  await openFixture(page)
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 844 })
    await page.goto('/')
    const active = page.locator('.aiur-shell__item[aria-current="page"]')
    const accentSoft = await active.evaluate(item => {
      const probe = document.createElement('span')
      probe.style.backgroundColor = 'var(--aiur-color-accent-soft)'
      item.append(probe)
      const color = getComputedStyle(probe).backgroundColor
      probe.remove()
      return color
    })
    await expect(active).toHaveCSS('background-color', accentSoft)
    const radii = await page.locator('.snav.is-active').evaluate(item => {
      const style = getComputedStyle(item)
      return [style.borderTopLeftRadius, style.borderBottomLeftRadius, style.borderTopRightRadius, style.borderBottomRightRadius]
    })
    expect(radii.slice(0, 2)).toEqual(width > 960 ? ['0px', '0px'] : ['10px', '10px'])
    expect(radii.slice(2).every(radius => radius !== '0px')).toBe(true)
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

      // Settings stays reachable above the fixed phone navigation.
      await page.locator('#ax-cog').click()
      await page.locator('#theme-toggle').click()
      await page.keyboard.press('Escape')
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')

      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
      await nextPaint(page)
      await assertNoDocumentOverflow(page)
      await expect(page.locator('#route-shell-action')).toBeVisible()

      if (width <= 960) {
        const reservedSpace = await page.evaluate(() => {
          const app = document.querySelector('section.dashboard-shell')
          const navigation = document.querySelector('aside.sidenav')
          const rect = navigation.getBoundingClientRect()

          return {
            navigation: rect.height + window.innerHeight - rect.bottom,
            padding: Number.parseFloat(getComputedStyle(app).paddingBlockEnd)
          }
        })

        expect(reservedSpace.padding).toBeGreaterThanOrEqual(reservedSpace.navigation)
      } else {
        const topbar = page.locator('header.ax-top')
        const initialTop = (await topbar.boundingBox()).y

        await page.evaluate(() => {
          const spacer = document.createElement('div')
          spacer.style.height = '1200px'
          spacer.setAttribute('aria-hidden', 'true')
          document.querySelector('section.dashboard-shell').append(spacer)
          window.scrollTo(0, 600)
        })
        await nextPaint(page)

        expect((await topbar.boundingBox()).y).toBeCloseTo(initialTop, 0)
        // The sidebar runs the full page height on a long page, and its links stay pinned (#4886).
        const rail = await page.evaluate(() => ({
          sidebar: document.querySelector('aside.sidenav').getBoundingClientRect().bottom,
          layout: document.querySelector('.app-layout').getBoundingClientRect().bottom
        }))
        expect(rail.sidebar).toBeCloseTo(rail.layout, 0)
        await expect(page.locator('a.snav').first()).toBeInViewport()
      }

      const accessibility = await new AxeBuilder({ page }).analyze()
      expect(accessibility.violations).toEqual([])
    } finally {
      await context.close()
    }
  })
}

test('a stored light theme never paints a dark frame and the toggle persists under aiur-theme', async ({ page }) => {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.addInitScript(() => {
    window.localStorage.setItem('aiur-theme', 'light')
    window.__themes = []
    // documentElement does not exist yet at init time. Records every data-theme the document takes after the server's "dark" markup default.
    new MutationObserver(() => window.__themes.push(document.documentElement.dataset.theme))
      .observe(document, { attributes: true, subtree: true, attributeFilter: ['data-theme'] })
    requestAnimationFrame(() => window.__themes.push(document.documentElement.dataset.theme))
  })

  await page.goto('/palette-probe') // the production root layout
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)

  const themes = await page.evaluate(() => window.__themes)
  expect(themes[0]).toBe('light')
  expect(themes).toContain('light')
  expect(themes).not.toContain('dark')
  await page.evaluate(() => document.fonts.ready)
  expect(await page.evaluate(() => document.fonts.check('16px "Space Grotesk"'))).toBe(true)
  // The pre-paint work comes from the aiur-style script, not an inline copy, and the toggle imports its module.
  expect(await page.locator('script[src="/aiur-style/init/theme-init.js"]').count()).toBe(1)
  expect(await page.evaluate(() => [...document.scripts].some((s) => !s.src && s.textContent.includes('aiur-theme')))).toBe(false)
  await expect.poll(() => page.evaluate(() => performance.getEntriesByType('resource').some((r) => r.name.endsWith('/aiur-style/js/theme.js')))).toBe(true)

  await page.locator('#ax-cog').click()
  await page.locator('#theme-toggle').click()
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark')
  await expect.poll(() => page.evaluate(() => window.localStorage.getItem('aiur-theme'))).toBe('dark')
})

test('production navigation restores and persists through the shared storage helper', async ({ page }) => {
  // Observe calls at the module boundary while delegating to the real guarded helper.
  // ThemeToggle imports this module too, so a resource request alone proves nothing.
  await page.route('**/aiur-style/js/storage.js', async route => {
    const actual = new URL('/aiur-style/js/storage.js?actual', route.request().url()).href
    await route.fulfill({ contentType: 'application/javascript', body: `
      import * as storage from ${JSON.stringify(actual)};
      window.navStorageCalls = [];
      export function readStorage(key) {
        window.navStorageCalls.push(['read', key]); return storage.readStorage(key);
      }
      export function writeStorage(key, value) {
        window.navStorageCalls.push(['write', key, value]); storage.writeStorage(key, value);
      }
    ` })
  })
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.evaluate(() => localStorage.setItem('aiur-nav-collapsed', 'true'))
  await page.goto('/palette-probe')
  const drag = page.locator('#ax-drag')
  await expect(drag).toHaveAttribute('data-nav-collapsed', 'true')
  await expect(page.locator('.aiur-shell__brand')).toHaveCSS('width', '60px')
  await drag.press('ArrowRight')
  await expect(drag).toHaveAttribute('data-nav-collapsed', 'false')
  await expect.poll(() => page.evaluate(() => localStorage.getItem('aiur-nav-collapsed'))).toBe('false')
  await expect.poll(() => page.evaluate(() => window.navStorageCalls)).toContainEqual(['write', 'aiur-nav-collapsed', 'false'])
  await page.reload()
  await expect(drag).toHaveAttribute('data-nav-collapsed', 'false')
  await expect.poll(() => page.evaluate(() => window.navStorageCalls)).toContainEqual(['read', 'aiur-nav-collapsed'])
})


test('migrated ghost button links keep the dashboard muted ink', async ({ page }) => {
  await openFixture(page)
  await page.goto('/commands/answered-command')
  const link = page.getByRole('link', { name: 'Collapse details' })
  await expect(link).toBeVisible()
  const ink = await link.evaluate(node => {
    const probe = document.createElement('span')
    probe.style.color = 'var(--muted)'
    node.append(probe)
    const color = getComputedStyle(probe).color
    probe.remove()
    return color
  })
  await expect(link).toHaveCSS('color', ink)
})

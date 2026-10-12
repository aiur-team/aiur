import { expect, test } from '@playwright/test'
import { assertControlsRemainReachable, assertNoDocumentOverflow, openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

const routes = [
  { path: '/', title: 'Units' },
  { path: '/commands', title: 'Commands' },
  { path: '/commands/decision-123', title: 'Commands' },
  { path: '/build-orders', title: 'Build Order' },
  { path: '/build-orders/42', title: 'Build Order #42' },
  { path: '/analytics', title: 'Analytics' },
  { path: '/streamdeck', title: 'Streamdeck+' }
]

const viewports = [360, 390, 768, 900, 959, 960, 1100, 1280, 1440, 1920, 2560]

const sidebarBreakpoint = 961

const navCollapsedStorageKey = 'aiur-nav-collapsed'

async function newShellContext(browser, { width, collapsed }) {
  const context = await browser.newContext({
    viewport: { width, height: 900 },
    reducedMotion: 'reduce',
    httpCredentials: dashboardCredentials,
    ...(width < sidebarBreakpoint ? { isMobile: true, hasTouch: true } : {})
  })

  await context.addInitScript(
    ({ key, value }) => {
      window.localStorage.setItem(key, value)

      document.addEventListener('DOMContentLoaded', () => {
        document.documentElement.style.overflowY = 'scroll'
      }, { once: true })
    },
    { key: navCollapsedStorageKey, value: String(collapsed) }
  )

  return context
}

async function openRoute(page, route, collapsed) {
  const response = await page.goto(route.path)

  expect(response?.status(), route.path).toBe(200)
  await expect(page.locator('#route-title')).toHaveText(route.title)
  await expect(page.locator('section.dashboard-shell')).toBeVisible()

  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)

  if (route.path === '/build-orders/42') await expect(page.locator('#selected-build-order-graph [data-bo-card]').first()).toBeVisible()

  expect(await page.evaluate((key) => window.localStorage.getItem(key), navCollapsedStorageKey)).toBe(String(collapsed))
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', String(collapsed))

  if (collapsed) {
    await expect.poll(() => page.locator('.ax-brand').evaluate(node => node.getBoundingClientRect().width)).toBe(60)
  }
}

function collectPageErrors(page) {
  const errors = []

  page.on('pageerror', (error) => errors.push(error.message))
  return errors
}

async function assertNoDocumentOverflowStrict(page) {
  const dimensions = await page.evaluate(() => ({
    clientWidth: document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
    bodyScrollWidth: document.body.scrollWidth
  }))

  expect(dimensions.scrollWidth).toBeLessThanOrEqual(dimensions.clientWidth)
  expect(dimensions.bodyScrollWidth).toBeLessThanOrEqual(dimensions.clientWidth)
}

async function measureShell(page) {
  return page.evaluate(() => {
    const shell = document.querySelector('section.dashboard-shell')
    const content = shell.getBoundingClientRect()
    const layout = document.querySelector('.app-layout').getBoundingClientRect()
    const nav = document.querySelector('aside.sidenav').getBoundingClientRect()
    return {
      measure: Number.parseFloat(getComputedStyle(shell).maxWidth),
      content: Math.round(content.width),
      centre: Math.round(content.x + content.width / 2),
      columnCentre: Math.round((window.innerWidth > 960 ? nav.right : layout.left) + (layout.right - (window.innerWidth > 960 ? nav.right : layout.left)) / 2),
      column: Math.round(layout.width - (window.innerWidth > 960 ? nav.width : 0))
    }
  })
}

for (const width of viewports) {
  const collapsedStates = width >= sidebarBreakpoint ? [false, true] : [false]

  for (const collapsed of collapsedStates) {
    const label = width >= sidebarBreakpoint ? `${width}px with the sidebar ${collapsed ? 'collapsed' : 'open'}` : `${width}px`

    test(`every route renders the same content width at ${label}`, async ({ browser }) => {
      const context = await newShellContext(browser, { width, collapsed })
      const page = await context.newPage()
      const pageErrors = collectPageErrors(page)

      try {
        await openFixture(page)

        const measured = new Map()

        for (const route of routes) {
          await openRoute(page, route, collapsed)

          await assertNoDocumentOverflow(page)
          await assertNoDocumentOverflowStrict(page)
          await assertControlsRemainReachable(page)

          measured.set(route.path, await measureShell(page))
        }

        expect(pageErrors).toEqual([])

        expect(measured.size).toBe(routes.length)

        const widths = [...measured].map(([path, { content }]) => [path, content])
        const distinct = new Set(widths.map(([, content]) => content))

        expect(distinct.size, `content widths per route: ${JSON.stringify(widths)}`).toBe(1)

        for (const [path, { content, column, measure }] of measured) {
          expect(measure, `max-width at ${path}`).toBeGreaterThan(0)
          expect(content, `content column at ${path}`).toBe(Math.min(measure, column))
        }
      } finally {
        await context.close()
      }
    })
  }
}

test('the content column settles on the shared measure, centred in the available column', async ({ browser }) => {
  const context = await newShellContext(browser, { width: 2560, collapsed: false })
  const page = await context.newPage()
  const pageErrors = collectPageErrors(page)

  try {
    await openFixture(page)

    for (const route of routes) {
      await openRoute(page, route, false)

      const { measure, content, centre, columnCentre } = await measureShell(page)

      expect(measure).toBe(1720)
      expect(content, `content column at ${route.path}`).toBe(measure)

      expect(Math.abs(centre - columnCentre), `centring at ${route.path}`).toBeLessThanOrEqual(20)
    }

    expect(pageErrors).toEqual([])
  } finally {
    await context.close()
  }
})

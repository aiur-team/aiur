import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

const layoutClientPath = /^\/vendor\/layout\/client-v1\/[a-f0-9]{64}\/aiur-layout-client\.js$/

async function openCatalog(page) {
  const stylesheet = page.waitForResponse((response) => new URL(response.url()).pathname === '/dashboard.css')
  await page.goto('/build-orders')
  await expect((await stylesheet).status()).toBe(200)
  await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-catalog-state', 'ready')
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await expect(page.locator('.dashboard-shell')).toHaveCSS('display', 'grid')
}

async function openCatalogEntry(page, title) {
  const entry = page.locator('.bo-catalog-entry', { hasText: title })
  await entry.getByRole('link', { name: 'Open graph' }).click()
}

async function interceptProductionLayoutClient(context, source) {
  const requests = []

  await context.route('**/vendor/layout/client-v1/*/aiur-layout-client.js', async (route) => {
    const pathname = new URL(route.request().url()).pathname

    if (!layoutClientPath.test(pathname)) return route.continue()

    requests.push(pathname)
    await route.fulfill({ status: 200, contentType: 'application/javascript', body: source })
  })

  return requests
}

test('production dependency context relationships remain clickable', async ({ page }) => {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await openCatalog(page)
  await openCatalogEntry(page, 'Release dashboard')

  const graph = page.locator('#selected-build-order-graph')
  const target = graph.locator('.bo-layout-card', { hasText: 'Readiness target' })
  await target.getByRole('button', { name: /Open cached context/ }).click()

  const dialog = page.getByRole('dialog', { name: 'Readiness target' })
  const dependency = dialog.getByRole('button', { name: 'Completed dependency' })
  await expect(dependency).toBeVisible()
  await dependency.click()
  await expect(page.getByRole('dialog', { name: 'Completed dependency' })).toBeVisible()
})

test('production Build Order route keeps catalog, graph truth, context, and URL history scoped', async ({ browser }) => {
  const context = await browser.newContext({
    httpCredentials: dashboardCredentials,
    viewport: { width: 1280, height: 900 },
    reducedMotion: 'reduce'
  })
  const page = await context.newPage()

  try {
    await openCatalog(page)

    await expect(page.getByRole('heading', { name: 'Build Order catalog' })).toBeVisible()
    await expect(page.locator('.bo-catalog-entry')).toHaveCount(3)
    await expect(page.locator('.bo-catalog-entry', { hasText: 'Unqualified root' })).toContainText('Invalid entry')
    await expect(page.getByRole('link', { name: 'Open graph' })).toHaveCount(2)

    await openCatalogEntry(page, 'Release dashboard')
    await expect(page).toHaveURL(/\/build-orders\/42$/)
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-status', 'selected')
    await expect(page.getByRole('heading', { name: 'Release dashboard' })).toBeVisible()

    const graph = page.locator('#selected-build-order-graph')
    await expect(graph.locator('[data-layout-node]')).toHaveCount(7)
    await expect(graph).toHaveAttribute('data-layout-root-id', '42')
    await expect(graph).toHaveAttribute('data-layout-provider-generation', '7')
    await expect(graph.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()

    for (const state of ['cleared', 'blocking', 'terminal_unsatisfied', 'unknown', 'cyclic']) {
      await expect(graph.locator(`[data-layout-edge-state="${state}"]`).first()).toBeVisible()
    }

    await expect(graph.getByText('External reference').first()).toBeVisible()
    await expect(graph.getByText('Dependency is outside the configured repository.').first()).toBeVisible()
    await expect(graph.locator('.bo-layout-card', { hasText: 'Readiness target' }).getByText('Review', { exact: true })).toBeVisible()
    await expect(graph.locator('.bo-layout-card', { hasText: 'Readiness target' }).getByText('60%', { exact: true })).toBeVisible()
    await expect(graph.locator('.bo-layout-card', { hasText: 'Unknown dependency' }).locator('[data-icon-key="lane_generic"]')).toBeVisible()

    const target = graph.locator('.bo-layout-card', { hasText: 'Readiness target' })
    const contextTrigger = target.getByRole('button', { name: /Open cached context/ })
    await contextTrigger.focus()
    await page.keyboard.press('Enter')

    const dialog = page.getByRole('dialog', { name: 'Readiness target' })
    await expect(dialog).toBeVisible()
    await expect(dialog.getByRole('heading', { name: 'Readiness target' })).toBeFocused()
    await expect(dialog.getByRole('heading', { name: 'Blocked by' })).toBeVisible()
    await expect(dialog.getByRole('link', { name: 'Issue' })).toHaveAttribute('href', 'https://github.com/owner/repo/issues/5')

    await dialog.getByRole('button', { name: 'Completed dependency' }).click()
    const replacement = page.getByRole('dialog', { name: 'Completed dependency' })
    await expect(replacement).toBeVisible()
    await replacement.getByRole('button', { name: 'Back' }).click()
    await expect(page.getByRole('dialog', { name: 'Readiness target' })).toBeVisible()

    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    await expect(contextTrigger).toBeFocused()

    await page.getByRole('link', { name: 'All Build Orders' }).click()
    await expect(page).toHaveURL(/\/build-orders$/)
    await openCatalogEntry(page, 'Stale planning lane')

    await expect(page).toHaveURL(/\/build-orders\/43$/)
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-status', 'selected_stale')
    await expect(page.getByRole('heading', { name: 'Stale last-known-good graph' })).toBeVisible()
    await expect(page.locator('#selected-build-order-graph [data-layout-node]')).toHaveCount(1)

    await page.goBack()
    await expect(page).toHaveURL(/\/build-orders$/)
    await expect(page.getByRole('heading', { name: 'Build Order catalog' })).toBeVisible()
    await page.goForward()
    await expect(page).toHaveURL(/\/build-orders\/43$/)
    await expect(page.getByRole('heading', { name: 'Stale planning lane' })).toBeVisible()

    await page.reload()
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-root', '43')
    await expect(page.locator('#selected-build-order-graph [data-layout-node]')).toHaveCount(1)

    const mutationEvents = await page.locator('[phx-click]').evaluateAll((elements) =>
      elements.map((element) => element.getAttribute('phx-click')).filter(Boolean)
    )
    expect(mutationEvents.every((event) => event === 'open-ticket-context')).toBe(true)
    await expect(page.locator('form')).toHaveCount(0)
    await assertNoDocumentOverflow(page)

    const accessibility = await new AxeBuilder({ page }).analyze()
    expect(accessibility.violations).toEqual([])
  } finally {
    await context.close()
  }
})

test('production route preserves semantic fallback when layout work fails', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const clientModules = await interceptProductionLayoutClient(context, `
    export function createLayoutWorkerClient() {
      return {
        dispose() {},
        layout(request) {
          return Promise.resolve({
            type: 'error',
            version: 1,
            requestId: request.requestId,
            generation: request.generation,
            error: { code: 'forced_route_fallback', message: 'Forced production-route fallback.' }
          })
        }
      }
    }
  `)
  const page = await context.newPage()

  try {
    await page.goto('/build-orders/42')
    await expect.poll(() => clientModules.length).toBe(1)
    expect(clientModules[0]).toMatch(layoutClientPath)
    const graph = page.locator('#selected-build-order-graph')
    await expect(graph).toHaveAttribute('data-layout-health', 'fallback')
    await expect(graph).toHaveAttribute('data-layout-failure', 'forced_route_fallback')
    await expect(graph.locator('[data-layout-node]')).toHaveCount(7)
    await expect(graph.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()
    await expect(graph.locator('svg[aria-hidden="true"] path')).toHaveCount(0)
  } finally {
    await context.close()
  }
})

test('production route rejects old-root layout completion after live navigation', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  await context.addInitScript(() => {
    window.__aiurRouteLayoutRequests = []
    window.__aiurRouteLayoutResolvers = []
  })
  const clientModules = await interceptProductionLayoutClient(context, `
    export function createLayoutWorkerClient() {
      return {
        dispose() {},
        layout(request) {
          globalThis.__aiurRouteLayoutRequests.push(request)
          return new Promise((resolve) => globalThis.__aiurRouteLayoutResolvers.push(() => resolve({
            type: 'result',
            version: 1,
            requestId: request.requestId,
            generation: request.generation,
            nodes: request.nodes.map((node, index) => ({
              ...node,
              x: (index % 4) * 220 + 1,
              y: Math.floor(index / 4) * 160 + 1
            })),
            edges: request.edges.map((edge, index) => ({
              id: edge.id,
              sections: [{
                startPoint: { x: index * 2 + 1, y: 1 },
                bendPoints: [],
                endPoint: { x: index * 2 + 2, y: 2 }
              }]
            }))
          })))
        }
      }
    }
  `)
  const page = await context.newPage()

  try {
    await page.goto('/build-orders/42')
    await expect.poll(() => clientModules.length).toBe(1)
    expect(clientModules[0]).toMatch(layoutClientPath)
    await expect.poll(() => page.evaluate(() =>
      window.__aiurRouteLayoutRequests.some((request) => request.nodes.length === 7)
    )).toBe(true)

    await page.getByRole('link', { name: 'All Build Orders' }).click()
    await openCatalogEntry(page, 'Stale planning lane')
    const currentGraph = page.locator('#selected-build-order-graph')
    await expect(currentGraph).toHaveAttribute('data-layout-root-id', '43')
    await expect.poll(() => page.evaluate(() =>
      window.__aiurRouteLayoutRequests.some((request) => request.nodes.length === 1)
    )).toBe(true)

    const oldRootRequest = await page.evaluate(() =>
      window.__aiurRouteLayoutRequests.findIndex((request) => request.nodes.length === 7)
    )

    await page.evaluate((index) => window.__aiurRouteLayoutResolvers[index](), oldRootRequest)
    await expect(currentGraph).toHaveAttribute('data-layout-root-id', '43')
    await expect(currentGraph).not.toHaveClass(/is-layout-ready/)

    await expect.poll(async () => {
      await page.evaluate(() => window.__aiurRouteLayoutRequests.forEach((request, index) => {
        if (request.nodes.length === 1) window.__aiurRouteLayoutResolvers[index]()
      }))
      return currentGraph.getAttribute('data-layout-health')
    }).toBe('ready')
    await expect(currentGraph).toHaveAttribute('data-layout-provider-generation', '8')
  } finally {
    await context.close()
  }
})

test('production Build Order routes enforce Basic Auth and reject malformed locators', async ({ browser }) => {
  const unauthenticated = await browser.newContext()
  const deniedPage = await unauthenticated.newPage()

  try {
    const response = await deniedPage.goto('/build-orders')
    expect(response?.status()).toBe(401)
  } finally {
    await unauthenticated.close()
  }

  const authenticated = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await authenticated.newPage()

  try {
    await page.goto('/build-orders/01')
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-status', 'invalid_parameter')
    await expect(page.getByRole('heading', { name: 'Invalid Build Order URL' })).toBeVisible()
    await expect(page.locator('[data-layout-node]')).toHaveCount(0)
  } finally {
    await authenticated.close()
  }
})

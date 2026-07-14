import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { captureConfiguredScreenshot, openFixture } from './support/browser-helpers.mjs'

test('DOM/SVG adapter keeps cards semantic while applying worker geometry and stateful edges', async ({ browser }, testInfo) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const root = page.locator('#fixture-build-order-graph')
    await expect(root).toHaveAttribute('data-layout-health', 'ready')
    await expect(root).toHaveClass(/is-layout-ready/)
    await expect(root.locator('[data-layout-node]')).toHaveCount(20)
    await expect(root.locator('[data-layout-dependency-summary] li')).toHaveCount(20)
    await expect(root.locator('svg[aria-hidden="true"]')).toBeAttached()
    await expect(root.locator('.bo-layout-edge.is-cleared')).toHaveCount(4)
    await expect(root.locator('.bo-layout-edge.is-blocking')).toHaveCount(4)
    await expect(root.locator('.bo-layout-edge.is-terminal_unsatisfied')).toHaveCount(4)
    await expect(root.locator('.bo-layout-edge.is-unknown')).toHaveCount(4)
    await expect(root.locator('.bo-layout-edge.is-cyclic')).toHaveCount(3)
    await expect(root.getByText('missing:fixture-node', { exact: true })).toBeVisible()
    await expect(root.locator('[data-layout-edge-path="fixture-missing-endpoint"]')).toHaveCount(0)

    const semanticOrder = await root.locator('[data-layout-node]').evaluateAll((cards) => cards.map((card) => card.dataset.layoutNodeId))
    expect(semanticOrder.slice(0, 4)).toEqual(['fixture-node-001', 'fixture-node-009', 'fixture-node-017', 'fixture-node-003'])
    await captureConfiguredScreenshot(page, testInfo)

    const hookInstance = await root.getAttribute('data-layout-hook-instance')
    await page.locator('#live-update').click()
    await expect(page.locator('#fixture-counts')).toContainText('nodes: 50')
    await expect(root).toHaveAttribute('data-layout-health', 'ready')
    await expect(root.locator('[data-layout-node]')).toHaveCount(50)
    await expect(root.locator('[data-layout-dependency-summary] li')).toHaveCount(49)
    await expect(root).toHaveAttribute('data-layout-hook-instance', hookInstance || '')
    await expect(root).toHaveAttribute('data-layout-hook-count', '1')
  } finally {
    await context.close()
  }
})

test('adapter retains deterministic document-flow fallback when the worker is unavailable', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)
    const root = page.locator('#fixture-build-order-graph')

    await page.locator('#force-layout-fallback').click()
    await expect(root).toHaveAttribute('data-layout-health', 'fallback')
    await expect(root).toHaveClass(/is-layout-fallback/)
    await expect(root.locator('[data-layout-node]')).toHaveCount(20)
    await expect(root.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()
    await expect(root.locator('[data-layout-dependency-summary] .bo-layout-edge-state', { hasText: 'Unknown' }).first()).toBeVisible()
    await expect(root.locator('svg[aria-hidden="true"] path')).toHaveCount(0)

    await page.locator('#restore-layout-worker').click()
    await expect(root).toHaveAttribute('data-layout-health', 'ready')
  } finally {
    await context.close()
  }
})

test('adapter falls back on worker timeout/error responses without removing semantic content', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  await context.addInitScript(() => {
    window.__aiurBrowserLayoutClientFactory = () => ({
      dispose() {},
      layout(request) {
        return Promise.resolve({
          type: 'error',
          version: 1,
          requestId: request.requestId,
          generation: request.generation,
          error: { code: 'request_timeout', message: 'Layout worker timed out.' }
        })
      }
    })
  })

  const page = await context.newPage()

  try {
    await openFixture(page)
    const root = page.locator('#fixture-build-order-graph')

    await expect(root).toHaveAttribute('data-layout-health', 'fallback')
    await expect(root).toHaveAttribute('data-layout-failure', 'request_timeout')
    await expect(root.locator('[data-layout-node]')).toHaveCount(20)
    await expect(root.locator('[data-layout-dependency-summary] li')).toHaveCount(20)
  } finally {
    await context.close()
  }
})

test('adapter validation rejects stale and malformed geometry before it can render', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(async () => {
      const { matchesLayoutContext, validateLayoutResult } = await import('/aiur-dom-svg-layout-adapter.js')
      const request = {
        requestId: 'request_3_1',
        generation: 3,
        nodes: [{ id: 'node_0', width: 100, height: 40 }],
        edges: []
      }
      const context = {
        rootId: 'root', providerGeneration: 1, domGeneration: 2, measurementVersion: 3, viewportWidth: 800, viewportHeight: 600, windowWidth: 800, windowHeight: 600
      }
      const valid = {
        type: 'result', version: 1, requestId: 'request_3_1', generation: 3, nodes: [{ id: 'node_0', x: 20, y: 30, width: 100, height: 40 }], edges: []
      }

      return {
        valid: validateLayoutResult(valid, request),
        malformed: validateLayoutResult({ ...valid, nodes: [{ ...valid.nodes[0], x: 0 }] }, request),
        wrongGeneration: validateLayoutResult({ ...valid, generation: 4 }, request),
        wrongVersion: validateLayoutResult({ ...valid, version: 2 }, request),
        matching: matchesLayoutContext(context, { ...context }),
        stale: matchesLayoutContext({ ...context, domGeneration: 3 }, context)
      }
    })

    expect(result).toEqual({ valid: true, malformed: false, wrongGeneration: false, wrongVersion: false, matching: true, stale: false })
  } finally {
    await context.close()
  }
})

test('adapter discards an old worker response after a LiveView graph update', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  await context.addInitScript(() => {
    window.__aiurLayoutRequests = []
    window.__aiurLayoutAutoResolve = false
    window.__aiurLayoutResponseFor = (request) => ({
      type: 'result',
      version: 1,
      requestId: request.requestId,
      generation: request.generation,
      nodes: request.nodes.map((node, index) => ({ ...node, x: (index % 10) * 300 + 1, y: Math.floor(index / 10) * 200 + 1 })),
      edges: request.edges.map((edge, index) => ({
        id: edge.id,
        sections: [{ startPoint: { x: 2, y: index + 2 }, bendPoints: [], endPoint: { x: 3, y: index + 2 } }]
      }))
    })
    window.__aiurBrowserLayoutClientFactory = () => ({
      dispose() {},
      layout(request) {
        if (window.__aiurLayoutAutoResolve) return Promise.resolve(window.__aiurLayoutResponseFor(request))
        return new Promise((resolve) => window.__aiurLayoutRequests.push({ request, resolve }))
      }
    })
  })

  const page = await context.newPage()

  try {
    await openFixture(page)
    const root = page.locator('#fixture-build-order-graph')

    await expect.poll(() => page.evaluate(() => window.__aiurLayoutRequests.length)).toBeGreaterThan(0)
    const initialRequestCount = await page.evaluate(() => window.__aiurLayoutRequests.length)
    await page.locator('#live-update').click()
    await expect.poll(() => page.evaluate(() => window.__aiurLayoutRequests.length)).toBeGreaterThan(initialRequestCount)

    await page.evaluate(() => {
      const first = window.__aiurLayoutRequests[0]
      first.resolve(window.__aiurLayoutResponseFor(first.request))
    })
    await expect(root).toHaveAttribute('data-layout-discarded-response', 'stale')

    await page.evaluate(() => {
      window.__aiurLayoutAutoResolve = true
      window.__aiurLayoutRequests.slice(1).forEach(({ request, resolve }) => resolve(window.__aiurLayoutResponseFor(request)))
    })
    await expect(root).toHaveAttribute('data-layout-health', 'ready')
  } finally {
    await context.close()
  }
})

test('the server-rendered fallback is readable when JavaScript is unavailable', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await page.goto('/auth/read_only')
    await expect(page).toHaveURL(/\/fixture$/)
    const root = page.locator('#fixture-build-order-graph')
    await expect(root).toHaveClass(/is-layout-fallback/)
    await expect(root.locator('[data-layout-node]')).toHaveCount(20)
    await expect(root.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()
    await expect(root.locator('[data-layout-dependency-summary] .bo-layout-edge-state', { hasText: 'Cyclic' }).first()).toBeVisible()
  } finally {
    await context.close()
  }
})

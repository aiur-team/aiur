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

    const statePatterns = await root.evaluate((element) => Object.fromEntries(
      ['cleared', 'blocking', 'terminal_unsatisfied', 'unknown', 'cyclic'].map((state) => {
        const path = element.querySelector(`.bo-layout-edge.is-${state}`)
        return [state, getComputedStyle(path).strokeDasharray]
      })
    ))
    expect(new Set(Object.values(statePatterns)).size).toBe(5)
    await page.emulateMedia({ forcedColors: 'active' })
    const forcedColorPatterns = await root.evaluate((element) => Object.fromEntries(
      ['cleared', 'blocking', 'terminal_unsatisfied', 'unknown', 'cyclic'].map((state) => {
        const path = element.querySelector(`.bo-layout-edge.is-${state}`)
        return [state, getComputedStyle(path).strokeDasharray]
      })
    ))
    expect(new Set(Object.values(forcedColorPatterns)).size).toBe(5)
    await page.emulateMedia({ forcedColors: 'none' })
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
    await expect(root.locator('svg[aria-hidden="true"]')).not.toHaveAttribute('viewBox')
    await expect(root.locator('svg[aria-hidden="true"]')).not.toHaveAttribute('width')
    await expect(root.locator('svg[aria-hidden="true"]')).not.toHaveAttribute('height')

    await page.locator('#restore-layout-worker').click()
    await expect(root).toHaveAttribute('data-layout-health', 'ready')
  } finally {
    await context.close()
  }
})

test('loader preserves the semantic fallback when its adapter module cannot load', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()
  await page.route('**/aiur-dom-svg-layout-adapter.js', (route) => route.abort())

  try {
    await openFixture(page)
    const root = page.locator('#fixture-build-order-graph')

    await expect(root).toHaveAttribute('data-layout-health', 'fallback')
    await expect(root).toHaveClass(/is-layout-fallback/)
    await expect(root.locator('[data-layout-node]')).toHaveCount(20)
    await expect(root.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()
    await expect(root.locator('[data-layout-dependency-summary] li')).toHaveCount(20)
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

test('production adapter falls back on client startup and malformed geometry while preserving semantic content', async ({ browser }) => {
  const startupContext = await browser.newContext({ httpCredentials: dashboardCredentials })
  await startupContext.addInitScript(() => {
    window.__aiurClientStartupAttempts = 0
    window.__aiurBrowserLayoutHookOptions = () => ({
      document: { documentElement: document.documentElement, fonts: new EventTarget() },
      clientFactory: (urls) => window.__aiurBrowserLayoutClientFactory(urls),
      createResizeObserver() {
        return { observe() {}, disconnect() {} }
      },
      createMutationObserver() {
        return { observe() {}, disconnect() {} }
      }
    })
    window.__aiurBrowserLayoutClientFactory = () => {
      window.__aiurClientStartupAttempts += 1
      if (window.__aiurClientStartupAttempts === 1) return Promise.reject(new Error('worker_start_failed'))

      const client = {
        dispose() {},
        layout(request) {
          return Promise.resolve({
            type: 'result',
            version: 1,
            requestId: request.requestId,
            generation: request.generation,
            nodes: request.nodes.map((node, index) => ({ ...node, x: index * 10 + 1, y: index * 10 + 1 })),
            edges: request.edges.map((edge) => ({
              id: edge.id,
              sections: [{ startPoint: { x: 1, y: 1 }, bendPoints: [], endPoint: { x: 10, y: 10 } }]
            }))
          })
        }
      }

      return new Promise((resolve) => {
        window.__aiurResolveStartupClient = () => resolve(client)
      })
    }
  })
  const startupPage = await startupContext.newPage()

  const malformedContext = await browser.newContext({ httpCredentials: dashboardCredentials })
  await malformedContext.addInitScript(() => {
    window.__aiurBrowserLayoutClientFactory = () => ({
      dispose() {},
      layout(request) {
        return Promise.resolve({
          type: 'result',
          version: 1,
          requestId: request.requestId,
          generation: request.generation,
          nodes: [],
          edges: []
        })
      }
    })
  })
  const malformedPage = await malformedContext.newPage()

  try {
    await openFixture(startupPage)
    const startupRoot = startupPage.locator('#fixture-build-order-graph')
    await expect(startupRoot).toHaveAttribute('data-layout-health', 'fallback')
    await expect(startupRoot).toHaveAttribute('data-layout-failure', 'worker_start_failed')
    await expect(startupRoot.locator('[data-layout-node]')).toHaveCount(20)
    await expect(startupRoot.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()
    await startupPage.locator('#live-update').click()
    await expect.poll(() => startupPage.evaluate(() => typeof window.__aiurResolveStartupClient)).toBe('function')
    await startupPage.evaluate(() => window.__aiurResolveStartupClient())
    await expect(startupRoot).toHaveAttribute('data-layout-health', 'ready')
    expect(await startupPage.evaluate(() => window.__aiurClientStartupAttempts)).toBe(2)

    await openFixture(malformedPage)
    const malformedRoot = malformedPage.locator('#fixture-build-order-graph')
    await expect(malformedRoot).toHaveAttribute('data-layout-health', 'fallback')
    await expect(malformedRoot).toHaveAttribute('data-layout-failure', 'malformed_geometry')
    await expect(malformedRoot.locator('[data-layout-node]')).toHaveCount(20)
    await expect(malformedRoot.getByRole('heading', { name: 'Dependency summary' })).toBeVisible()
  } finally {
    await startupContext.close()
    await malformedContext.close()
  }
})

test('adapter validation rejects stale and malformed geometry before it can render', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(async () => {
      const { measureLayout } = await import('/aiur-dom-svg-layout/measurement.js')
      const { matchesLayoutContext, validateLayoutResult } = await import('/aiur-dom-svg-layout/protocol.js')
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
      const extentRequest = { ...request, nodes: [{ id: 'node_0', width: 4096, height: 40 }] }
      const extentOverflow = {
        ...valid,
        nodes: [{ id: 'node_0', x: 4096, y: 30, width: 4096, height: 40 }]
      }
      const root = document.querySelector('#fixture-build-order-graph')
      root.querySelector('[data-layout-card-header]').remove()
      const measurementInvalid = measureLayout(root, { clientEpoch: 1, layoutGeneration: 1, measurementVersion: 1 }) === null

      return {
        valid: validateLayoutResult(valid, request),
        malformed: validateLayoutResult({ ...valid, nodes: [{ ...valid.nodes[0], x: 0 }] }, request),
        wrongGeneration: validateLayoutResult({ ...valid, generation: 4 }, request),
        wrongVersion: validateLayoutResult({ ...valid, version: 2 }, request),
        extentOverflow: validateLayoutResult(extentOverflow, extentRequest),
        matching: matchesLayoutContext(context, { ...context }),
        rootMismatch: matchesLayoutContext({ ...context, rootId: 'replacement-root' }, context),
        providerMismatch: matchesLayoutContext({ ...context, providerGeneration: 2 }, context),
        stale: matchesLayoutContext({ ...context, domGeneration: 3 }, context),
        measurementMismatch: matchesLayoutContext({ ...context, measurementVersion: 4 }, context),
        viewportMismatch: matchesLayoutContext({ ...context, viewportWidth: 801 }, context),
        measurementInvalid
      }
    })

    expect(result).toEqual({
      valid: true,
      malformed: false,
      wrongGeneration: false,
      wrongVersion: false,
      extentOverflow: false,
      matching: true,
      rootMismatch: false,
      providerMismatch: false,
      stale: false,
      measurementMismatch: false,
      viewportMismatch: false,
      measurementInvalid: true
    })
  } finally {
    await context.close()
  }
})

test('adapter accepts bounded maximum graph inputs beyond a 4096px document context', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(async () => {
      const { measureLayout, readRootContext } = await import('/aiur-dom-svg-layout/measurement.js')
      const root = document.createElement('section')
      root.dataset.layoutRootId = 'maximum-fixture-root'
      root.dataset.layoutProviderGeneration = '1'
      root.dataset.layoutDomGeneration = '1'
      root.getBoundingClientRect = () => ({ width: 5_000, height: 8_000 })

      const cards = document.createElement('div')
      cards.dataset.layoutCards = ''
      root.append(cards)

      for (let index = 0; index < 100; index += 1) {
        const card = document.createElement('article')
        card.dataset.layoutNode = ''
        card.dataset.layoutNodeId = `node-${index}`
        card.dataset.layoutLane = String(index % 10)
        card.dataset.layoutPhase = String(index % 10)
        card.getBoundingClientRect = () => ({ width: 160, height: 64 })

        const header = document.createElement('header')
        header.dataset.layoutCardHeader = ''
        header.getBoundingClientRect = () => ({ width: 160, height: 24 })
        card.append(header)
        cards.append(card)
      }

      for (let index = 0; index < 1_000; index += 1) {
        const edge = document.createElement('li')
        edge.dataset.layoutEdge = ''
        edge.dataset.layoutEdgeSource = `node-${index % 100}`
        edge.dataset.layoutEdgeTarget = `node-${(index + 1) % 100}`
        edge.dataset.layoutEdgeState = 'blocking'
        root.append(edge)
      }

      const widthDescriptor = Object.getOwnPropertyDescriptor(window, 'innerWidth')
      const heightDescriptor = Object.getOwnPropertyDescriptor(window, 'innerHeight')
      Object.defineProperty(window, 'innerWidth', { configurable: true, value: 5_000 })
      Object.defineProperty(window, 'innerHeight', { configurable: true, value: 6_000 })

      try {
        const measured = measureLayout(root, { clientEpoch: 1, layoutGeneration: 1, measurementVersion: 1 })
        const documentContext = readRootContext(root, 1)
        root.getBoundingClientRect = () => ({ width: 1_000_000, height: 1_000_000 })
        Object.defineProperty(window, 'innerWidth', { configurable: true, value: 1_000_000 })
        Object.defineProperty(window, 'innerHeight', { configurable: true, value: 1_000_000 })
        const contextAtLimit = readRootContext(root, 1)
        root.getBoundingClientRect = () => ({ width: 1_000_001, height: 1_000_001 })
        Object.defineProperty(window, 'innerWidth', { configurable: true, value: 1_000_001 })
        Object.defineProperty(window, 'innerHeight', { configurable: true, value: 1_000_001 })

        return {
          documentContext,
          contextAtLimit,
          contextOverflow: readRootContext(root, 1),
          nodeCount: measured?.request.nodes.length,
          edgeCount: measured?.request.edges.length
        }
      } finally {
        Object.defineProperty(window, 'innerWidth', widthDescriptor)
        Object.defineProperty(window, 'innerHeight', heightDescriptor)
      }
    })

    expect(result).toMatchObject({
      documentContext: { viewportWidth: 5_000, viewportHeight: 6_000, windowWidth: 5_000, windowHeight: 6_000 },
      contextAtLimit: { viewportWidth: 1_000_000, viewportHeight: 1_000_000, windowWidth: 1_000_000, windowHeight: 1_000_000 },
      contextOverflow: null,
      nodeCount: 100,
      edgeCount: 1_000
    })
  } finally {
    await context.close()
  }
})

test('adapter dense-ranks sparse semantic lane and phase values for worker layout', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(async () => {
      const { measureLayout } = await import('/aiur-dom-svg-layout/measurement.js')
      const root = document.createElement('section')
      root.dataset.layoutRootId = 'sparse-semantic-root'
      root.dataset.layoutProviderGeneration = '1'
      root.dataset.layoutDomGeneration = '1'
      root.getBoundingClientRect = () => ({ width: 800, height: 600 })

      const cards = document.createElement('div')
      cards.dataset.layoutCards = ''
      root.append(cards)

      const semantics = [
        { lane: 5_000, phase: 100 },
        { lane: 100, phase: 500_000 },
        { lane: 5_000, phase: 9_000 }
      ]

      semantics.forEach(({ lane, phase }, index) => {
        const card = document.createElement('article')
        card.dataset.layoutNode = ''
        card.dataset.layoutNodeId = `sparse-node-${index}`
        card.dataset.layoutLane = String(lane)
        card.dataset.layoutPhase = String(phase)
        card.getBoundingClientRect = () => ({ width: 160, height: 64 })

        const header = document.createElement('header')
        header.dataset.layoutCardHeader = ''
        header.getBoundingClientRect = () => ({ width: 160, height: 24 })
        card.append(header)
        cards.append(card)
      })

      const measured = measureLayout(root, { clientEpoch: 1, layoutGeneration: 1, measurementVersion: 1 })

      return {
        constraints: measured?.request.constraints,
        domSemantics: Array.from(cards.children, (card) => ({
          lane: card.dataset.layoutLane,
          phase: card.dataset.layoutPhase
        })),
        workerNodes: measured?.request.nodes.map(({ lane, phase }) => ({ lane, phase }))
      }
    })

    expect(result).toEqual({
      constraints: {
        lanes: [{ index: 0 }, { index: 1 }],
        phases: [{ index: 0 }, { index: 1 }, { index: 2 }]
      },
      domSemantics: [
        { lane: '5000', phase: '100' },
        { lane: '100', phase: '500000' },
        { lane: '5000', phase: '9000' }
      ],
      workerNodes: [
        { lane: 1, phase: 0 },
        { lane: 0, phase: 2 },
        { lane: 1, phase: 1 }
      ]
    })
  } finally {
    await context.close()
  }
})

test('adapter discards late worker responses after root replacement and a LiveView graph update', async ({ browser }) => {
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
    await page.evaluate(() => {
      document.querySelector('#fixture-build-order-graph').dataset.layoutRootId = 'replacement-root'
      const first = window.__aiurLayoutRequests[0]
      first.resolve(window.__aiurLayoutResponseFor(first.request))
    })
    await expect(root).toHaveAttribute('data-layout-discarded-response', 'stale')
    await page.evaluate(() => {
      document.querySelector('#fixture-build-order-graph').dataset.layoutRootId = 'fixture-build-order-root'
    })
    await page.locator('#live-update').click()
    await expect.poll(() => page.evaluate(() => window.__aiurLayoutRequests.length)).toBeGreaterThan(initialRequestCount)

    await page.evaluate(() => {
      window.__aiurLayoutAutoResolve = true
      window.__aiurLayoutRequests.slice(1).forEach(({ request, resolve }) => resolve(window.__aiurLayoutResponseFor(request)))
    })
    await expect(root).toHaveAttribute('data-layout-health', 'ready')
  } finally {
    await context.close()
  }
})

test('production hook remeasures font, theme, text zoom, and resize changes before redrawing geometry', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  await context.addInitScript(() => {
    window.__aiurLayoutRequests = []
    window.__aiurLayoutLifecycle = []
    window.__aiurLayoutLifecycleEvents = []
    window.__aiurTestFonts = new EventTarget()
    window.__aiurTestFonts.ready = Promise.resolve()
    document.addEventListener('aiur:layout-lifecycle', ({ detail }) => window.__aiurLayoutLifecycleEvents.push(detail))
    window.__aiurLayoutResponseFor = (request) => ({
      type: 'result',
      version: 1,
      requestId: request.requestId,
      generation: request.generation,
      nodes: request.nodes.map((node, index) => ({ ...node, x: (index % 5) * 700 + 1, y: Math.floor(index / 5) * 200 + 1 })),
      edges: request.edges.map((edge) => ({
        id: edge.id,
        sections: [{
          startPoint: { x: 1, y: request.nodes[0].height },
          bendPoints: [],
          endPoint: { x: 2, y: request.nodes[0].height + 1 }
        }]
      }))
    })
    window.__aiurBrowserLayoutHookOptions = () => ({
      document: { documentElement: document.documentElement, fonts: window.__aiurTestFonts },
      clientFactory: () => ({
        dispose() {},
        layout(request) {
          window.__aiurLayoutRequests.push(JSON.parse(JSON.stringify(request)))
          return Promise.resolve(window.__aiurLayoutResponseFor(request))
        }
      }),
      onLifecycle(event, detail) {
        window.__aiurLayoutLifecycle.push({ event, source: detail.source })
      }
    })
  })

  const page = await context.newPage()

  try {
    await openFixture(page)
    const root = page.locator('#fixture-build-order-graph')
    const firstPath = root.locator('[data-layout-edge-path]').first()
    await expect(root).toHaveAttribute('data-layout-health', 'ready')
    const before = await page.evaluate(() => ({
      count: window.__aiurLayoutRequests.length,
      height: window.__aiurLayoutRequests.at(-1).nodes[0].height,
      sources: window.__aiurLayoutLifecycle.filter(({ event }) => event === 'remeasure').map(({ source }) => source)
    }))
    const beforePath = await firstPath.getAttribute('d')

    await page.evaluate(() => {
      document.documentElement.dataset.theme = 'dark'
      document.documentElement.style.fontSize = '200%'
      document.querySelector('[data-layout-node]').style.fontSize = '32px'
      window.__aiurTestFonts.dispatchEvent(new Event('loadingdone'))
      window.dispatchEvent(new Event('resize'))
    })

    await expect.poll(() => page.evaluate(() => window.__aiurLayoutRequests.length)).toBeGreaterThan(before.count)
    await expect.poll(() => page.evaluate(() => window.__aiurLayoutRequests.at(-1).nodes[0].height)).toBeGreaterThan(before.height)
    await expect.poll(() => firstPath.getAttribute('d')).not.toBe(beforePath)

    const sources = await page.evaluate(() => window.__aiurLayoutLifecycle.filter(({ event }) => event === 'remeasure').map(({ source }) => source))
    expect(sources).toEqual(expect.arrayContaining([...before.sources, 'font', 'resize', 'theme']))
    const observedSources = await page.evaluate(() => window.__aiurLayoutLifecycleEvents.filter(({ event }) => event === 'remeasure').map(({ source }) => source))
    expect(observedSources).toEqual(expect.arrayContaining(['font', 'resize', 'theme']))
  } finally {
    await context.close()
  }
})

test('production hook disposes workers and observers across LiveView teardown, remount, and reconnect', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  await context.addInitScript(() => {
    window.__aiurLayoutRequests = 0
    window.__aiurLayoutDisposals = 0
    window.__aiurLayoutObserverDisconnects = 0
    window.__aiurLayoutObserverCallbacks = []
    window.__aiurLayoutThemeObserverDisconnects = 0
    window.__aiurLayoutThemeObserverCallbacks = []
    window.__aiurLayoutLifecycle = []
    window.__aiurTestFonts = new EventTarget()
    window.__aiurTestFonts.ready = Promise.resolve()
    window.__aiurBrowserLayoutHookOptions = () => ({
      document: { documentElement: document.documentElement, fonts: window.__aiurTestFonts },
      clientFactory: () => ({
        dispose() { window.__aiurLayoutDisposals += 1 },
        layout(request) {
          window.__aiurLayoutRequests += 1
          return Promise.resolve({
            type: 'result',
            version: 1,
            requestId: request.requestId,
            generation: request.generation,
            nodes: request.nodes.map((node, index) => ({ ...node, x: (index % 5) * 700 + 1, y: Math.floor(index / 5) * 200 + 1 })),
            edges: request.edges.map((edge) => ({ id: edge.id, sections: [{ startPoint: { x: 1, y: 1 }, bendPoints: [], endPoint: { x: 2, y: 2 } }] }))
          })
        }
      }),
      createResizeObserver(callback) {
        window.__aiurLayoutObserverCallbacks.push(callback)
        return {
          observe() {},
          disconnect() { window.__aiurLayoutObserverDisconnects += 1 }
        }
      },
      createMutationObserver(callback) {
        window.__aiurLayoutThemeObserverCallbacks.push(callback)
        return {
          observe() {},
          disconnect() { window.__aiurLayoutThemeObserverDisconnects += 1 }
        }
      },
      onLifecycle(event) { window.__aiurLayoutLifecycle.push(event) }
    })
  })

  const page = await context.newPage()

  try {
    await openFixture(page)
    const root = page.locator('#fixture-build-order-graph')
    await expect(root).toHaveAttribute('data-layout-health', 'ready')
    const beforeTeardown = await page.evaluate(() => ({
      requests: window.__aiurLayoutRequests,
      disconnects: window.__aiurLayoutObserverDisconnects,
      themeDisconnects: window.__aiurLayoutThemeObserverDisconnects
    }))

    await page.locator('#unmount-graph').click()
    await expect(page.locator('#graph-unmounted')).toBeVisible()
    await expect(root).toHaveCount(0)
    await expect.poll(() => page.evaluate(() => window.__aiurLayoutDisposals)).toBe(1)

    await page.evaluate(() => {
      window.__aiurLayoutObserverCallbacks.forEach((callback) => callback([]))
      window.__aiurLayoutThemeObserverCallbacks.forEach((callback) => callback([]))
      window.__aiurTestFonts.dispatchEvent(new Event('loadingdone'))
      window.dispatchEvent(new Event('resize'))
    })
    await page.waitForTimeout(100)
    expect(await page.evaluate(() => window.__aiurLayoutRequests)).toBe(beforeTeardown.requests)
    expect(await page.evaluate(() => window.__aiurLayoutObserverDisconnects)).toBeGreaterThan(beforeTeardown.disconnects)
    expect(await page.evaluate(() => window.__aiurLayoutThemeObserverDisconnects)).toBeGreaterThan(beforeTeardown.themeDisconnects)
    expect(await page.evaluate(() => window.__aiurLayoutLifecycle)).toContain('destroyed')

    await page.locator('#remount-graph').click()
    await expect(root).toHaveAttribute('data-layout-health', 'ready')
    await expect(root).toHaveAttribute('data-layout-hook-count', '1')

    await page.evaluate(() => window.liveSocket.disconnect())
    await expect(page.locator('#worker-status')).toHaveAttribute('data-live-status', 'disconnected')
    await page.evaluate(() => window.liveSocket.connect())
    await expect(page.locator('#worker-status')).toHaveAttribute('data-live-status', 'reconnected')
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

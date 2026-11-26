import { expect, test } from '@playwright/test'
import { openFixture } from '../support/browser-helpers.mjs'
import { dashboardCredentials, layoutAssetUrls, layoutRequest } from '../support/layout-worker.mjs'

test('local worker returns bounded geometry off the browser main thread', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine })
      const mainThreadMarker = new Promise((resolve) => setTimeout(() => resolve('ran'), 0))
      let settled = false
      const layout = client.layout(payload.request).finally(() => { settled = true })
      const marker = await mainThreadMarker
      const pendingWhenMarkerRan = !settled
      const response = await layout
      client.dispose()
      return { marker, pendingWhenMarkerRan, response }
    }, { urls, request: layoutRequest(100, { generation: 2, cycle: true, externalStub: true }) })

    expect(result.marker).toBe('ran')
    expect(result.pendingWhenMarkerRan).toBe(true)
    expect(result.response).toMatchObject({ type: 'result', version: 1, requestId: 'request_2_100', generation: 2 })
    expect(result.response.nodes).toHaveLength(100)
    expect(result.response.edges).toHaveLength(100)
    expect(result.response.nodes.every((node) => Number.isFinite(node.x) && node.x >= 1 && node.x <= 4096)).toBe(true)
    expect(result.response.nodes.every((node) => Number.isFinite(node.y) && node.y >= 1 && node.y <= 4096)).toBe(true)
    expect(result.response.edges.every((edge) => edge.sections.length > 0)).toBe(true)
    expect(result.response.edges.every((edge) => edge.sections.every((section) => {
      const points = [section.startPoint, ...section.bendPoints, section.endPoint]
      return points.every((point) => Number.isFinite(point.x) && point.x >= 1 && point.x <= 4096 && Number.isFinite(point.y) && point.y >= 1 && point.y <= 4096)
    }))).toBe(true)
    expect(result.response.diagnostics).toEqual([{ code: 'external_stubs', count: 1 }])
  } finally {
    await context.close()
  }
})

test('worker preserves directed order and repeated constrained geometry', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()
  const request = layoutRequest(20, { generation: 6 })
  const samePartitionRequest = {
    ...request,
    nodes: request.nodes.map((node) => ({ ...node, lane: 0, phase: 0 }))
  }

  try {
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine })
      const first = await client.layout(payload.request)
      const second = await client.layout(payload.request)
      client.dispose()

      const positions = new Map(first.nodes.map((node) => [node.id, node]))
      const directedOrder = payload.request.edges.every(({ source, target }) => positions.get(source).x < positions.get(target).x)

      return { first, second, directedOrder }
    }, { urls, request: samePartitionRequest })

    expect(result.first.type).toBe('result')
    expect(result.directedOrder).toBe(true)
    expect(result.second).toEqual(result.first)
  } finally {
    await context.close()
  }
})

test('worker preserves independent lane and phase order across multiple roots and disconnected components', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()
  const multipleRootRequest = {
    type: 'layout',
    version: 1,
    requestId: 'request_7_42',
    generation: 7,
    constraints: {
      lanes: [{ index: 3 }, { index: 8 }],
      phases: [{ index: 2 }, { index: 9 }]
    },
    nodes: [
      { id: 'node_42', width: 120, height: 48, lane: 8, phase: 9 },
      { id: 'node_7', width: 120, height: 48, lane: 8, phase: 2 },
      { id: 'node_18', width: 120, height: 48, lane: 3, phase: 9 },
      { id: 'node_3', width: 120, height: 48, lane: 3, phase: 2 }
    ],
    edges: [
      { id: 'edge_19', source: 'node_7', target: 'node_42' },
      { id: 'edge_4', source: 'node_3', target: 'node_18' }
    ],
    options: { direction: 'RIGHT', edgeRouting: 'ORTHOGONAL', randomSeed: 1, thoroughness: 1, considerModelOrder: true }
  }
  const disconnectedRequest = {
    ...multipleRootRequest,
    requestId: 'request_8_42',
    generation: 8,
    edges: []
  }
  const reorderedRequest = {
    ...multipleRootRequest,
    requestId: 'request_9_42',
    generation: 9,
    nodes: [...multipleRootRequest.nodes].reverse(),
    edges: [...multipleRootRequest.edges].reverse()
  }

  try {
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine })
      const first = await client.layout(payload.multipleRootRequest)
      const reordered = await client.layout(payload.reorderedRequest)
      const disconnected = await client.layout(payload.disconnectedRequest)
      client.dispose()
      return { first, reordered, disconnected }
    }, { urls, multipleRootRequest, reorderedRequest, disconnectedRequest })

    for (const layout of [result.first, result.disconnected]) {
      const positions = new Map(layout.nodes.map((node) => [node.id, node]))
      const phaseLow = ['node_3', 'node_7'].map((id) => positions.get(id).x)
      const phaseHigh = ['node_18', 'node_42'].map((id) => positions.get(id).x)
      const laneLow = ['node_3', 'node_18'].map((id) => positions.get(id).y)
      const laneHigh = ['node_7', 'node_42'].map((id) => positions.get(id).y)

      expect(layout.type).toBe('result')
      expect(Math.max(...phaseLow)).toBeLessThan(Math.min(...phaseHigh))
      expect(Math.max(...laneLow)).toBeLessThan(Math.min(...laneHigh))
    }

    const coordinateMap = (layout) => Object.fromEntries(layout.nodes.map(({ id, x, y }) => [id, { x, y }]))
    expect(coordinateMap(result.reordered)).toEqual(coordinateMap(result.first))
  } finally {
    await context.close()
  }
})

test('direct worker returns bounded routed geometry for a one-node self-loop', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()
  const request = {
    ...layoutRequest(1, { generation: 10 }),
    edges: [{ id: 'edge_0', source: 'node_0', target: 'node_0' }]
  }

  try {
    await openFixture(page)

    const result = await page.evaluate(async (payload) => new Promise((resolve, reject) => {
      const worker = new Worker(`${payload.urls.worker}?engine=${encodeURIComponent(payload.urls.engine)}`)
      worker.addEventListener('message', (event) => {
        worker.terminate()
        resolve(event.data)
      }, { once: true })
      worker.addEventListener('error', (event) => {
        worker.terminate()
        reject(new Error(event.message || 'direct worker failed'))
      }, { once: true })
      worker.postMessage(payload.request)
    }), { urls, request })

    expect(result).toMatchObject({ type: 'result', requestId: 'request_10_1', generation: 10 })
    expect(result.nodes).toHaveLength(1)
    expect(result.edges).toHaveLength(1)
    expect(result.edges[0].sections.length).toBeGreaterThan(0)
    expect(result.edges[0].sections.flatMap((section) => [section.startPoint, ...section.bendPoints, section.endPoint]).every((point) =>
      Number.isFinite(point.x) && point.x >= 1 && point.x <= 4096 && Number.isFinite(point.y) && point.y >= 1 && point.y <= 4096
    )).toBe(true)
  } finally {
    await context.close()
  }
})

test('worker maps model-order preference to a documented ELK strategy', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()
  const request = {
    type: 'layout',
    version: 1,
    requestId: 'request_11_5',
    generation: 11,
    constraints: { lanes: [], phases: [] },
    nodes: Array.from({ length: 5 }, (_, index) => ({ id: `node_${index}`, width: 120, height: 48 })),
    edges: [
      { id: 'edge_0', source: 'node_0', target: 'node_1' },
      { id: 'edge_1', source: 'node_0', target: 'node_2' },
      { id: 'edge_2', source: 'node_0', target: 'node_3' }
    ],
    options: { direction: 'RIGHT', edgeRouting: 'ORTHOGONAL', randomSeed: 1, thoroughness: 1, considerModelOrder: true }
  }
  const unorderedRequest = {
    ...request,
    requestId: 'request_12_5',
    generation: 12,
    options: { ...request.options, considerModelOrder: false }
  }

  try {
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine })
      const ordered = await client.layout(payload.request)
      const unordered = await client.layout(payload.unorderedRequest)
      client.dispose()
      return { ordered, unordered }
    }, { urls, request, unorderedRequest })

    const ordered = new Map(result.ordered.nodes.map((node) => [node.id, node.y]))
    const unordered = new Map(result.unordered.nodes.map((node) => [node.id, node.y]))

    expect(result.ordered.type).toBe('result')
    expect(result.unordered.type).toBe('result')
    expect(ordered.get('node_1')).toBeLessThan(ordered.get('node_2'))
    expect(ordered.get('node_2')).toBeLessThan(ordered.get('node_3'))
    expect([unordered.get('node_1'), unordered.get('node_2'), unordered.get('node_3')]).not.toEqual([
      ordered.get('node_1'), ordered.get('node_2'), ordered.get('node_3')
    ])
  } finally {
    await context.close()
  }
})

test('worker supports empty through 50-node graph fixtures with stable identities', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const results = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine })
      const responses = await Promise.all(payload.requests.map((request) => client.layout(request)))
      client.dispose()
      return responses
    }, { urls, requests: [0, 1, 20, 50].map((count, index) => layoutRequest(count, { generation: index + 1 })) })

    for (const [index, response] of results.entries()) {
      expect(response).toMatchObject({ type: 'result', requestId: `request_${index + 1}_${[0, 1, 20, 50][index]}`, generation: index + 1 })
      expect(response.nodes).toHaveLength([0, 1, 20, 50][index])
    }
  } finally {
    await context.close()
  }
})


// Regression for #1270: the real Build Order graph (#1084 shape — 54 nodes,
// 106 edges, 8 phase partitions, real card dimensions) laid out to a canvas
// wider than the former 4095px coordinate cap, so the worker threw
// `layout_overflow` (and the client's coordinate validation would have rejected
// it), collapsing the graph to the document-flow fallback with zero edges. The
// previous large-graph coverage only exercised the fixture's deliberately
// bounded sqrt-grid shape, which never crosses the cap — that gap is why the
// overflow shipped. This drives a genuinely deep, wide-card graph end to end
// through client + worker and asserts geometry is produced (not an overflow
// error), with at least one coordinate beyond the old 4095 bound so the test
// fails against the pre-fix caps and passes only once they accommodate the
// real dataset.
function realWorldBuildOrderRequest() {
  const NODE_COUNT = 54
  const PHASES = 8
  const PER_PHASE = Math.ceil(NODE_COUNT / PHASES)
  const nodes = Array.from({ length: NODE_COUNT }, (_, index) => ({
    id: `node_${index}`,
    // Real Build Order cards are 14-18rem wide with multi-line content, far
    // larger than the 120x48 synthetic fixtures used elsewhere; a deep chain of
    // these is what pushes the layered canvas past the old bound.
    width: 260,
    height: 150,
    lane: index % 3,
    phase: Math.min(Math.floor(index / PER_PHASE), PHASES - 1)
  }))

  const edges = []
  const addEdge = (source, target) => edges.push({ id: `edge_${edges.length}`, source: `node_${source}`, target: `node_${target}` })
  for (let index = 1; index < NODE_COUNT; index++) addEdge(index - 1, index) // dependency spine (depth)
  for (let index = 2; index < NODE_COUNT; index++) addEdge(index - 2, index) // skip dependencies
  addEdge(0, 6) // one cross-phase long dependency -> 106 edges total

  return {
    type: 'layout',
    version: 1,
    requestId: `request_30_${NODE_COUNT}`,
    generation: 30,
    constraints: {
      lanes: [{ index: 0 }, { index: 1 }, { index: 2 }],
      phases: Array.from({ length: PHASES }, (_, index) => ({ index }))
    },
    nodes,
    edges,
    options: {
      direction: 'RIGHT',
      edgeRouting: 'ORTHOGONAL',
      randomSeed: 1,
      thoroughness: 1,
      considerModelOrder: true,
      favorStraightEdges: true
    }
  }
}

test('client and worker lay out the real #1084 Build Order shape past the former coordinate cap', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine })
      const response = await client.layout(payload.request)
      client.dispose()
      return response
    }, { urls, request: realWorldBuildOrderRequest() })

    // Layout succeeds instead of collapsing to the fallback: the client returns
    // a result envelope (a `layout_overflow` throw surfaces as `type: 'error'`).
    expect(result.type).toBe('result')
    expect(result.nodes).toHaveLength(54)
    expect(result.edges).toHaveLength(106)

    // Edges are actually routed — the fallback draws none, so every edge must
    // carry at least one section with routed points (SVG edge children).
    expect(result.edges.every((edge) => edge.sections.length > 0)).toBe(true)
    const routedPoints = result.edges.flatMap((edge) =>
      edge.sections.flatMap((section) => [section.startPoint, ...section.bendPoints, section.endPoint]))
    expect(routedPoints.length).toBeGreaterThan(0)

    const coordinates = [
      ...result.nodes.flatMap((node) => [node.x, node.y]),
      ...routedPoints.flatMap((point) => [point.x, point.y])
    ]

    // The graph genuinely exceeds the former 4095px cap; without the raised
    // bound the worker throws and the client rejects, so this line pins the
    // regression rather than merely re-testing an already-bounded graph.
    expect(Math.max(...coordinates)).toBeGreaterThan(4_096)

    // Coordinates remain finite, positive, and inside the raised guard — the
    // cap still bounds runaway geometry, it is only sized for the real dataset.
    expect(coordinates.every((value) => Number.isFinite(value) && value >= 1 && value <= 65_536)).toBe(true)
  } finally {
    await context.close()
  }
})

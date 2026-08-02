import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials, layoutAssetUrls, layoutRequest } from './support/layout-worker.mjs'

test('content-addressed layout assets require dashboard auth', async ({ browser, baseURL }) => {
  const urls = await layoutAssetUrls()
  const denied = await browser.newContext()

  try {
    const page = await denied.newPage()
    const response = await page.goto(new URL(urls.worker, baseURL).href)
    expect(response?.status()).toBe(401)
  } finally {
    await denied.close()
  }
})

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

test('worker protocol keeps failures and stale identities structured', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine })
      const malformed = await client.layout({ ...payload.request, title: 'must-not-cross-worker-boundary' })
      const oversized = await client.layout({
        ...payload.request,
        nodes: Array.from({ length: 101 }, (_, index) => ({ id: `node_${index}`, width: 1, height: 1 })),
        edges: []
      })
      const credentialShapedId = 'node_ghp_abcdefghijklmnopqrstuvwxyzabcdefghijk'
      const credentialShapedRequest = {
        ...payload.request,
        nodes: [{ ...payload.request.nodes[0], id: credentialShapedId }, ...payload.request.nodes.slice(1)],
        edges: payload.request.edges.map((edge) => edge.source === 'node_0' ? { ...edge, source: credentialShapedId } : edge)
      }
      const credentialShaped = await client.layout(credentialShapedRequest)
      const identityMismatch = await client.layout({ ...payload.request, generation: 10 })
      let serializationCalls = 0
      const hugeUnknownPreflight = await client.layout({
        ...payload.request,
        ignored: { toJSON() { serializationCalls += 1; return 'x'.repeat(512 * 1024) } }
      })
      const stale = await client.layout(payload.request)
      client.dispose()

      const directWorkerRequest = (request, workerUrl = `${payload.urls.worker}?engine=${encodeURIComponent(payload.urls.engine)}`) => new Promise((resolve, reject) => {
        const worker = new Worker(workerUrl)
        worker.addEventListener('message', (event) => {
          worker.terminate()
          resolve(event.data)
        }, { once: true })
        worker.addEventListener('error', (event) => {
          worker.terminate()
          reject(new Error(event.message || 'direct worker failed'))
        }, { once: true })
        worker.postMessage(request)
      })

      const directMalformed = await directWorkerRequest(credentialShapedRequest)
      const directOversized = await directWorkerRequest({
        ...payload.request,
        requestId: 'request_12_101',
        generation: 12,
        nodes: Array.from({ length: 101 }, (_, index) => ({ id: `node_${index}`, width: 1, height: 1 })),
        edges: []
      })
      const directInvalidConstraint = await directWorkerRequest({
        ...payload.request,
        nodes: [{ ...payload.request.nodes[0], lane: 99 }, ...payload.request.nodes.slice(1)]
      })
      const directIdentityMismatch = await directWorkerRequest({ ...payload.request, generation: 10 })
      const directHugeUnknown = await directWorkerRequest({ ...payload.request, ignored: 'x'.repeat(512 * 1024) })
      const sparse = (values) => {
        const copy = [...values]
        delete copy[0]
        return copy
      }
      const directSparseCollections = await Promise.all([
        directWorkerRequest({ ...payload.request, nodes: sparse(payload.request.nodes) }),
        directWorkerRequest({ ...payload.request, edges: sparse(payload.request.edges) }),
        directWorkerRequest({ ...payload.request, constraints: { ...payload.request.constraints, lanes: sparse(payload.request.constraints.lanes) } }),
        directWorkerRequest({ ...payload.request, constraints: { ...payload.request.constraints, phases: sparse(payload.request.constraints.phases) } })
      ])
      const directEngineQuery = await directWorkerRequest(payload.request, `${payload.urls.worker}?engine=${encodeURIComponent(`${payload.urls.engine}?cache=1`)}`)
      const directEngineHash = await directWorkerRequest(payload.request, `${payload.urls.worker}?engine=${encodeURIComponent(`${payload.urls.engine}#fragment`)}`)
      const directDuplicateEngine = await directWorkerRequest(payload.request, `${payload.urls.worker}?engine=${encodeURIComponent(payload.urls.engine)}&engine=${encodeURIComponent(payload.urls.engine)}`)
      const directExtraParameter = await directWorkerRequest(payload.request, `${payload.urls.worker}?engine=${encodeURIComponent(payload.urls.engine)}&debug=1`)

      let invalidPosts = 0
      let assetUrlConstructions = 0

      class RecordingWorker {
        constructor() { assetUrlConstructions += 1 }
        addEventListener() {}
        postMessage() { invalidPosts += 1 }
        terminate() {}
      }

      const preflight = await createLayoutWorkerClient({
        workerUrl: payload.urls.worker,
        engineUrl: payload.urls.engine,
        WorkerConstructor: RecordingWorker
      }).layout({ ...payload.request, title: 'must-not-cross-worker-boundary' })
      const clientSparseCollections = await Promise.all([
        createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine, WorkerConstructor: RecordingWorker }).layout({ ...payload.request, nodes: sparse(payload.request.nodes) }),
        createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine, WorkerConstructor: RecordingWorker }).layout({ ...payload.request, edges: sparse(payload.request.edges) }),
        createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine, WorkerConstructor: RecordingWorker }).layout({ ...payload.request, constraints: { ...payload.request.constraints, lanes: sparse(payload.request.constraints.lanes) } }),
        createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine, WorkerConstructor: RecordingWorker }).layout({ ...payload.request, constraints: { ...payload.request.constraints, phases: sparse(payload.request.constraints.phases) } })
      ])

      const credentialedWorkerUrl = new URL(payload.urls.worker, globalThis.location.href)
      credentialedWorkerUrl.username = 'layout'
      credentialedWorkerUrl.password = 'worker'
      const credentialedEngineUrl = new URL(payload.urls.engine, globalThis.location.href)
      credentialedEngineUrl.username = 'layout'
      credentialedEngineUrl.password = 'engine'
      const invalidAssetUrls = await Promise.all([
        createLayoutWorkerClient({ workerUrl: credentialedWorkerUrl.href, engineUrl: payload.urls.engine, WorkerConstructor: RecordingWorker }).layout(payload.request),
        createLayoutWorkerClient({ workerUrl: `${payload.urls.worker}?debug=1`, engineUrl: payload.urls.engine, WorkerConstructor: RecordingWorker }).layout(payload.request),
        createLayoutWorkerClient({ workerUrl: `${payload.urls.worker}#fragment`, engineUrl: payload.urls.engine, WorkerConstructor: RecordingWorker }).layout(payload.request),
        createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: credentialedEngineUrl.href, WorkerConstructor: RecordingWorker }).layout(payload.request),
        createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: `${payload.urls.engine}?cache=1`, WorkerConstructor: RecordingWorker }).layout(payload.request),
        createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: `${payload.urls.engine}#fragment`, WorkerConstructor: RecordingWorker }).layout(payload.request)
      ])

      const unsupported = await createLayoutWorkerClient({
        workerUrl: payload.urls.worker,
        engineUrl: payload.urls.engine,
        WorkerConstructor: undefined
      }).layout(payload.request)

      let constructions = 0

      class HungWorker {
        constructor() { constructions += 1 }
        addEventListener() {}
        postMessage() {}
        terminate() {}
      }

      const hungClient = createLayoutWorkerClient({
        workerUrl: payload.urls.worker,
        engineUrl: payload.urls.engine,
        timeoutMs: 1,
        WorkerConstructor: HungWorker
      })
      const timeout = await hungClient.layout(payload.request)
      const retry = await hungClient.layout({ ...payload.request, requestId: 'request_10_20', generation: 10 })
      hungClient.dispose()

      class MalformedWorker {
        constructor() { this.listeners = new Map() }
        addEventListener(name, callback) { this.listeners.set(name, callback) }
        postMessage() { queueMicrotask(() => this.listeners.get('message')?.({ data: { type: 'result' } })) }
        terminate() {}
      }

      const malformedResponse = await createLayoutWorkerClient({
        workerUrl: payload.urls.worker,
        engineUrl: payload.urls.engine,
        WorkerConstructor: MalformedWorker
      }).layout(payload.request)

      class MalformedGeometryWorker {
        constructor() { this.listeners = new Map() }
        addEventListener(name, callback) { this.listeners.set(name, callback) }
        postMessage(request) {
          queueMicrotask(() => this.listeners.get('message')?.({
            data: { type: 'result', version: 1, requestId: request.requestId, generation: request.generation, nodes: [], edges: [], diagnostics: [] }
          }))
        }
        terminate() {}
      }

      const malformedGeometry = await createLayoutWorkerClient({
        workerUrl: payload.urls.worker,
        engineUrl: payload.urls.engine,
        WorkerConstructor: MalformedGeometryWorker
      }).layout(payload.request)

      const validResult = (request) => ({
        type: 'result',
        version: 1,
        requestId: request.requestId,
        generation: request.generation,
        nodes: request.nodes.map((node) => ({ id: node.id, x: 1, y: 1, width: node.width, height: node.height })),
        edges: request.edges.map((edge) => ({ id: edge.id, sections: [] })),
        diagnostics: []
      })
      const responseWith = async (mutate) => {
        class ContractViolatingWorker {
          constructor() { this.listeners = new Map() }
          addEventListener(name, callback) { this.listeners.set(name, callback) }
          postMessage(request) {
            const response = validResult(request)
            mutate(response)
            queueMicrotask(() => this.listeners.get('message')?.({ data: response }))
          }
          terminate() {}
        }

        return createLayoutWorkerClient({
          workerUrl: payload.urls.worker,
          engineUrl: payload.urls.engine,
          WorkerConstructor: ContractViolatingWorker
        }).layout(payload.request)
      }
      const alteredDimensions = await responseWith((response) => { response.nodes[0].width += 1 })
      const fabricatedDiagnostics = await responseWith((response) => { response.diagnostics = [{ code: 'external_stubs', count: 1 }] })
      const sparseResponseCollections = await Promise.all([
        responseWith((response) => { response.nodes = sparse(response.nodes) }),
        responseWith((response) => { response.edges = sparse(response.edges) }),
        responseWith((response) => { response.diagnostics = sparse([{ code: 'external_stubs', count: 1 }]) }),
        responseWith((response) => {
          response.edges[0].sections = sparse([{ startPoint: { x: 1, y: 1 }, bendPoints: [], endPoint: { x: 2, y: 2 } }])
        }),
        responseWith((response) => {
          response.edges[0].sections = [{ startPoint: { x: 1, y: 1 }, bendPoints: sparse([{ x: 2, y: 2 }]), endPoint: { x: 3, y: 3 } }]
        })
      ])

      class StaleWorker {
        constructor() { this.listeners = new Map() }
        addEventListener(name, callback) { this.listeners.set(name, callback) }
        postMessage(request) {
          queueMicrotask(() => this.listeners.get('message')?.({
            data: { type: 'result', version: 1, requestId: 'request_1_20', generation: 1, nodes: [], edges: [], diagnostics: [] }
          }))
          queueMicrotask(() => this.listeners.get('message')?.({
            data: {
              type: 'result',
              version: 1,
              requestId: request.requestId,
              generation: request.generation,
              nodes: request.nodes.map((node) => ({ id: node.id, x: 1, y: 1, width: node.width, height: node.height })),
              edges: request.edges.map((edge) => ({ id: edge.id, sections: [] })),
              diagnostics: []
            }
          }))
        }
        terminate() {}
      }

      const staleResponse = await createLayoutWorkerClient({
        workerUrl: payload.urls.worker,
        engineUrl: payload.urls.engine,
        WorkerConstructor: StaleWorker
      }).layout(payload.request)

      const lateWorkers = []

      class LateWorker {
        constructor() {
          this.listeners = new Map()
          lateWorkers.push(this)
        }
        addEventListener(name, callback) { this.listeners.set(name, callback) }
        postMessage(request) {
          if (lateWorkers.length < 2) return
          queueMicrotask(() => this.listeners.get('message')?.({
            data: {
              type: 'result',
              version: 1,
              requestId: request.requestId,
              generation: request.generation,
              nodes: request.nodes.map((node) => ({ id: node.id, x: 1, y: 1, width: node.width, height: node.height })),
              edges: request.edges.map((edge) => ({ id: edge.id, sections: [] })),
              diagnostics: []
            }
          }))
        }
        terminate() {}
      }

      const lateClient = createLayoutWorkerClient({
        workerUrl: payload.urls.worker,
        engineUrl: payload.urls.engine,
        timeoutMs: 1,
        WorkerConstructor: LateWorker
      })
      const lateTimeout = await lateClient.layout(payload.request)
      const lateRecovery = lateClient.layout({ ...payload.request, requestId: 'request_11_20', generation: 11 })
      lateWorkers[0].listeners.get('message')?.({ data: { type: 'result' } })
      lateWorkers[0].listeners.get('error')?.({})
      lateWorkers[0].listeners.get('messageerror')?.({})
      const lateRecoveryResult = await lateRecovery
      lateClient.dispose()

      const duplicateClient = createLayoutWorkerClient({
        workerUrl: payload.urls.worker,
        engineUrl: payload.urls.engine,
        timeoutMs: 1,
        WorkerConstructor: HungWorker
      })
      const [firstDuplicate, secondDuplicate] = await Promise.all([
        duplicateClient.layout(payload.request),
        duplicateClient.layout(payload.request)
      ])
      duplicateClient.dispose()

      const engineFailure = await createLayoutWorkerClient({
        workerUrl: payload.urls.worker,
        engineUrl: payload.urls.engine.replace(/[a-f0-9]{64}/, '0000000000000000000000000000000000000000000000000000000000000000')
      }).layout(payload.request)

      return { malformed, oversized, credentialShaped, identityMismatch, hugeUnknownPreflight, serializationCalls, directMalformed, directOversized, directInvalidConstraint, directIdentityMismatch, directHugeUnknown, directSparseCollections, directEngineQuery, directEngineHash, directDuplicateEngine, directExtraParameter, stale, preflight, clientSparseCollections, invalidPosts, assetUrlConstructions, invalidAssetUrls, unsupported, timeout, retry, constructions, malformedResponse, malformedGeometry, alteredDimensions, fabricatedDiagnostics, sparseResponseCollections, staleResponse, lateTimeout, lateRecoveryResult, lateWorkers: lateWorkers.length, firstDuplicate, secondDuplicate, engineFailure }
    }, { urls, request: layoutRequest(20, { generation: 9, cycle: true }) })

    expect(result.malformed).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.malformed.error.message).not.toContain('must-not-cross-worker-boundary')
    expect(result.oversized).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.credentialShaped).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(JSON.stringify(result.credentialShaped)).not.toContain('ghp_')
    expect(result.identityMismatch).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 10, error: { code: 'invalid_request' } })
    expect(result.hugeUnknownPreflight).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.serializationCalls).toBe(0)
    expect(result.directMalformed).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.directOversized).toMatchObject({ type: 'error', requestId: 'request_12_101', generation: 12, error: { code: 'invalid_request' } })
    expect(result.directInvalidConstraint).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.directIdentityMismatch).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 10, error: { code: 'invalid_request' } })
    expect(result.directHugeUnknown).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(JSON.stringify(result.directHugeUnknown).length).toBeLessThan(256)
    expect(result.directSparseCollections).toHaveLength(4)
    expect(result.directSparseCollections.every((response) => response.error?.code === 'invalid_request')).toBe(true)
    expect(result.directEngineQuery).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'engine_unavailable' } })
    expect(result.directEngineHash).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'engine_unavailable' } })
    expect(result.directDuplicateEngine).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'engine_unavailable' } })
    expect(result.directExtraParameter).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'engine_unavailable' } })
    expect(JSON.stringify(result.directMalformed)).not.toContain('ghp_')
    expect(JSON.stringify(result.directOversized).length).toBeLessThan(256)
    expect(result.preflight).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.clientSparseCollections).toHaveLength(4)
    expect(result.clientSparseCollections.every((response) => response.error?.code === 'invalid_request')).toBe(true)
    expect(result.invalidPosts).toBe(0)
    expect(result.invalidAssetUrls).toHaveLength(6)
    expect(result.invalidAssetUrls.every((response) => response.error?.code === 'asset_url_invalid')).toBe(true)
    expect(result.assetUrlConstructions).toBe(0)
    expect(result.stale).toMatchObject({ type: 'result', requestId: 'request_9_20', generation: 9 })
    expect(result.unsupported).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'worker_unsupported' } })
    expect(result.timeout).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'request_timeout' } })
    expect(result.retry).toMatchObject({ type: 'error', requestId: 'request_10_20', generation: 10, error: { code: 'request_timeout' } })
    expect(result.constructions).toBe(3)
    expect(result.malformedResponse).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'malformed_response' } })
    expect(result.malformedGeometry).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'malformed_response' } })
    expect(result.alteredDimensions).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'malformed_response' } })
    expect(result.fabricatedDiagnostics).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'malformed_response' } })
    expect(result.sparseResponseCollections).toHaveLength(5)
    expect(result.sparseResponseCollections.every((response) => response.error?.code === 'malformed_response')).toBe(true)
    expect(result.staleResponse).toMatchObject({ type: 'result', requestId: 'request_9_20', generation: 9 })
    expect(result.lateTimeout).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'request_timeout' } })
    expect(result.lateRecoveryResult).toMatchObject({ type: 'result', requestId: 'request_11_20', generation: 11 })
    expect(result.lateWorkers).toBe(2)
    expect(result.firstDuplicate).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'request_timeout' } })
    expect(result.secondDuplicate).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.engineFailure).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'engine_failed' } })
  } finally {
    await context.close()
  }
})

test('worker validates direct boundary and client response matrices before geometry is trusted', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const workerUrl = `${payload.urls.worker}?engine=${encodeURIComponent(payload.urls.engine)}`
      const request = payload.request
      const directWorkerRequest = (candidate) => new Promise((resolve, reject) => {
        const worker = new Worker(workerUrl)
        worker.addEventListener('message', (event) => {
          worker.terminate()
          resolve(event.data)
        }, { once: true })
        worker.addEventListener('error', (event) => {
          worker.terminate()
          reject(new Error(event.message || 'direct worker failed'))
        }, { once: true })
        worker.postMessage(candidate)
      })
      const balancedHole = (values) => {
        const copy = [...values]
        const missing = copy[0]
        delete copy[0]
        copy.extra = missing
        return copy
      }
      const tooManyEdges = Array.from({ length: 1_001 }, (_, index) => ({ id: `edge_${index}`, source: 'node_0', target: 'node_1' }))
      const constraintLimitPlusOne = {
        lanes: Array.from({ length: 100 }, (_, index) => ({ index })),
        phases: [{ index: 0 }]
      }
      const optionLimitPlusOne = {
        direction: 'RIGHT',
        edgeRouting: 'ORTHOGONAL',
        nodeNodeSpacing: 1,
        layerSpacing: 1,
        randomSeed: 1,
        thoroughness: 1,
        considerModelOrder: true,
        favorStraightEdges: true,
        unknown: true
      }
      const directCases = {
        unsupportedVersion: { ...request, version: 2 },
        tooManyNodes: { ...request, nodes: Array.from({ length: 101 }, (_, index) => ({ id: `node_${index}`, width: 1, height: 1 })), edges: [] },
        tooManyEdges: { ...request, edges: tooManyEdges },
        tooManyConstraints: { ...request, constraints: constraintLimitPlusOne, nodes: request.nodes.map((node) => ({ ...node, phase: 0 })) },
        tooManyOptions: { ...request, options: optionLimitPlusOne },
        nonFiniteDimension: { ...request, nodes: [{ ...request.nodes[0], width: Infinity }, request.nodes[1]] },
        outOfRangeDimension: { ...request, nodes: [{ ...request.nodes[0], height: 4_097 }, request.nodes[1]] },
        balancedNodeHole: { ...request, nodes: balancedHole(request.nodes) },
        balancedEdgeHole: { ...request, edges: balancedHole(request.edges) },
        balancedLaneHole: { ...request, constraints: { ...request.constraints, lanes: balancedHole(request.constraints.lanes) } },
        balancedPhaseHole: { ...request, constraints: { ...request.constraints, phases: balancedHole(request.constraints.phases) } }
      }
      const direct = Object.fromEntries(await Promise.all(Object.entries(directCases).map(async ([name, candidate]) => [name, await directWorkerRequest(candidate)])))

      let invalidPosts = 0
      class RecordingWorker {
        addEventListener() {}
        postMessage() { invalidPosts += 1 }
        terminate() {}
      }

      const preflight = Object.fromEntries(await Promise.all(Object.entries(directCases).map(async ([name, candidate]) => [
        name,
        await createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine, WorkerConstructor: RecordingWorker }).layout(candidate)
      ])))

      const validResult = (candidate) => ({
        type: 'result',
        version: 1,
        requestId: candidate.requestId,
        generation: candidate.generation,
        nodes: candidate.nodes.map((node) => ({ id: node.id, x: 1, y: 1, width: node.width, height: node.height })),
        edges: candidate.edges.map((edge) => ({ id: edge.id, sections: [] })),
        diagnostics: []
      })
      const responseWith = async (mutate) => {
        class ContractViolatingWorker {
          constructor() { this.listeners = new Map() }
          addEventListener(name, callback) { this.listeners.set(name, callback) }
          postMessage(candidate) {
            const response = validResult(candidate)
            mutate(response)
            queueMicrotask(() => this.listeners.get('message')?.({ data: response }))
          }
          terminate() {}
        }

        return createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine, WorkerConstructor: ContractViolatingWorker }).layout(request)
      }
      const section = { startPoint: { x: 1, y: 1 }, bendPoints: [], endPoint: { x: 2, y: 2 } }
      const malformedResponses = Object.fromEntries(await Promise.all([
        ['duplicateNode', (response) => { response.nodes = [response.nodes[0], { ...response.nodes[0] }] }],
        ['missingNode', (response) => { response.nodes = response.nodes.slice(0, 1) }],
        ['extraNode', (response) => { response.nodes.push({ ...response.nodes[0], id: 'node_99' }) }],
        ['duplicateEdge', (response) => { response.edges = [response.edges[0], { ...response.edges[0] }] }],
        ['missingEdge', (response) => { response.edges = [] }],
        ['extraEdge', (response) => { response.edges.push({ ...response.edges[0], id: 'edge_99' }) }],
        ['nonFiniteCoordinate', (response) => { response.nodes[0].x = NaN }],
        ['outOfRangeCoordinate', (response) => { response.nodes[0].y = 65_537 }],
        ['excessSections', (response) => { response.edges[0].sections = Array.from({ length: 17 }, () => section) }],
        ['excessPoints', (response) => { response.edges[0].sections = [{ ...section, bendPoints: Array.from({ length: 63 }, () => ({ x: 1, y: 1 })) }] }],
        ['excessDiagnostics', (response) => { response.diagnostics = Array.from({ length: 11 }, () => ({ code: 'external_stubs', count: 1 })) }],
        ['balancedResultNodeHole', (response) => { response.nodes = balancedHole(response.nodes) }],
        ['balancedResultEdgeHole', (response) => { response.edges = balancedHole(response.edges) }],
        ['balancedDiagnosticsHole', (response) => { response.diagnostics = balancedHole([{ code: 'external_stubs', count: 1 }]) }],
        ['balancedSectionHole', (response) => { response.edges[0].sections = balancedHole([section]) }],
        ['balancedPointHole', (response) => { response.edges[0].sections = [{ ...section, bendPoints: balancedHole([{ x: 1, y: 1 }]) }] }]
      ].map(async ([name, mutate]) => [name, await responseWith(mutate)])))

      const maximumSection = await responseWith((response) => {
        response.edges[0].sections = [{ ...section, bendPoints: Array.from({ length: 62 }, () => ({ x: 1, y: 1 })) }]
      })

      return { direct, preflight, invalidPosts, malformedResponses, maximumSection }
    }, { urls, request: layoutRequest(2, { generation: 14 }) })

    expect(result.direct.unsupportedVersion).toMatchObject({ type: 'error', error: { code: 'unsupported_version' } })
    for (const [name, response] of Object.entries(result.direct)) {
      if (name === 'unsupportedVersion') continue
      expect(response).toMatchObject({ type: 'error', error: { code: 'invalid_request' } })
    }
    for (const response of Object.values(result.preflight)) {
      expect(response).toMatchObject({ type: 'error', error: { code: 'invalid_request' } })
    }
    expect(result.invalidPosts).toBe(0)
    for (const response of Object.values(result.malformedResponses)) {
      expect(response).toMatchObject({ type: 'error', error: { code: 'malformed_response' } })
    }
    expect(result.maximumSection.type).toBe('result')
    expect(result.maximumSection.edges[0].sections[0].bendPoints).toHaveLength(62)
  } finally {
    await context.close()
  }
})

test('worker rejects malformed engine identities and denied subresources with recoverable safe envelopes', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()
  const pageErrors = []
  page.on('pageerror', (error) => pageErrors.push(error.message))

  const malformedEngine = `self.onmessage = ({ data }) => {
    if (data.cmd === 'register') { self.postMessage({ id: data.id, data: {} }); return; }
    const children = data.graph.children.map((node, index) => ({ id: node.id, x: index, y: index }));
    const edges = data.graph.edges.map((edge) => ({ id: edge.id, sections: [] }));
    switch (data.graph.layoutOptions['elk.randomSeed']) {
      case '11': children[1] = { ...children[0] }; break;
      case '12': children.pop(); break;
      case '13': children.push({ id: 'node_99', x: 1, y: 1 }); break;
      case '14': edges.push({ ...edges[0] }); break;
      case '15': edges.pop(); break;
      case '16': edges.push({ id: 'edge_99', sections: [] }); break;
      case '17': edges[0] = { ...edges[0], sections: [{ startPoint: { x: 0, y: 0 }, bendPoints: Array.from({ length: 62 }, () => ({ x: 0, y: 0 })), endPoint: { x: 1, y: 1 } }] }; break;
      case '18': edges[0] = { ...edges[0], sections: [{ startPoint: { x: 0, y: 0 }, bendPoints: Array.from({ length: 63 }, () => ({ x: 0, y: 0 })), endPoint: { x: 1, y: 1 } }] }; break;
    }
    self.postMessage({ id: data.id, data: { children, edges } });
  };`

  try {
    await context.route(urls.engine, (route) => route.fulfill({ contentType: 'application/javascript', body: malformedEngine }))
    await openFixture(page)

    const engineOutput = await page.evaluate(async (payload) => {
      const directWorkerRequest = (request) => new Promise((resolve, reject) => {
        const worker = new Worker(`${payload.urls.worker}?engine=${encodeURIComponent(payload.urls.engine)}`)
        worker.addEventListener('message', (event) => {
          worker.terminate()
          resolve(event.data)
        }, { once: true })
        worker.addEventListener('error', (event) => {
          worker.terminate()
          reject(new Error(event.message || 'direct worker failed'))
        }, { once: true })
        worker.postMessage(request)
      })

      const responseFor = (seed) => directWorkerRequest({
        ...payload.request,
        requestId: `request_${seed}_2`,
        generation: seed,
        options: { ...payload.request.options, randomSeed: seed }
      })

      return {
        malformed: await Promise.all([11, 12, 13, 14, 15, 16].map(responseFor)),
        maximumSection: await responseFor(17),
        excessPoints: await responseFor(18)
      }
    }, { urls, request: layoutRequest(2, { generation: 10 }) })

    expect(engineOutput.malformed).toHaveLength(6)
    expect(engineOutput.malformed.every((response) => response.error?.code === 'invalid_engine_output')).toBe(true)
    expect(engineOutput.maximumSection).toMatchObject({ type: 'result', requestId: 'request_17_2', generation: 17 })
    expect(engineOutput.maximumSection.edges[0].sections[0].bendPoints).toHaveLength(62)
    expect(engineOutput.excessPoints).toMatchObject({ type: 'error', error: { code: 'invalid_engine_output' } })
    expect(pageErrors).toEqual([])
  } finally {
    await context.close()
  }

  const recoveryContext = await browser.newContext({ httpCredentials: dashboardCredentials })
  const recoveryPage = await recoveryContext.newPage()
  const recoveryErrors = []
  let engineRequests = 0
  recoveryPage.on('pageerror', (error) => recoveryErrors.push(error.message))

  try {
    await openFixture(recoveryPage)
    // The recovery block below exercises the standalone worker client module; it
    // only needs the fixture rendered. The graph itself is the synchronous grid
    // (no layout worker adapter), so assert the grid is present rather than a
    // removed `data-layout-health` state.
    await expect(recoveryPage.locator('#fixture-build-order-graph[data-bo-grid]')).toBeVisible()

    await recoveryContext.route(urls.engine, (route) => {
      engineRequests += 1
      return engineRequests === 1
        ? route.fulfill({ status: 404, contentType: 'application/javascript', body: '' })
        : route.continue()
    })

    const result = await recoveryPage.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const deniedDigest = '0'.repeat(64)
      const deniedWorkerUrl = payload.urls.worker.replace(/[a-f0-9]{64}/, deniedDigest)
      const deniedWorker = createLayoutWorkerClient({ workerUrl: deniedWorkerUrl, engineUrl: payload.urls.engine })
      const deniedEngine = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine })
      const workerResponse = await deniedWorker.layout(payload.request)
      const engineResponse = await deniedEngine.layout(payload.request)
      deniedWorker.dispose()
      const recovery = await deniedEngine.layout({ ...payload.request, requestId: 'request_18_2', generation: 18 })
      deniedEngine.dispose()
      return { workerResponse, engineResponse, recovery }
    }, { urls, request: layoutRequest(2, { generation: 17 }) })

    expect(result.workerResponse).toMatchObject({ type: 'error', requestId: 'request_17_2', generation: 17, error: { code: 'worker_failed' } })
    expect(result.engineResponse).toMatchObject({ type: 'error', requestId: 'request_17_2', generation: 17, error: { code: 'engine_failed' } })
    expect(result.recovery).toMatchObject({ type: 'result', requestId: 'request_18_2', generation: 18 })
    expect(engineRequests).toBe(2)
    expect(JSON.stringify([result.workerResponse, result.engineResponse]).length).toBeLessThan(512)
    expect(recoveryErrors).toEqual([])
  } finally {
    await recoveryContext.close()
  }
})

test('worker and client bound aggregate route geometry without delaying bounded responses', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()
  const pageErrors = []
  page.on('pageerror', (error) => pageErrors.push(error.message))

  const oversizedEngine = `self.onmessage = ({ data }) => {
    if (data.cmd === 'register') { self.postMessage({ id: data.id, data: {} }); return; }
    const section = { startPoint: { x: 0, y: 0 }, bendPoints: Array.from({ length: 7 }, () => ({ x: 0, y: 0 })), endPoint: { x: 1, y: 1 } };
    self.postMessage({ id: data.id, data: {
      children: data.graph.children.map((node, index) => ({ id: node.id, x: index, y: index })),
      edges: data.graph.edges.map((edge) => ({ id: edge.id, sections: [section] }))
    } });
  };`

  try {
    await context.route(urls.engine, (route) => route.fulfill({ contentType: 'application/javascript', body: oversizedEngine }))
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const workerUrl = `${payload.urls.worker}?engine=${encodeURIComponent(payload.urls.engine)}`
      const maximumRequest = {
        ...payload.request,
        requestId: 'request_19_100',
        generation: 19,
        constraints: { lanes: [{ index: 0 }], phases: [{ index: 0 }] },
        nodes: Array.from({ length: 100 }, (_, index) => ({ id: `node_${index}`, width: 1, height: 1, lane: 0, phase: 0 })),
        edges: Array.from({ length: 1_000 }, (_, index) => ({ id: `edge_${index}`, source: 'node_0', target: 'node_1' }))
      }
      const directWorkerRequest = (candidate) => new Promise((resolve, reject) => {
        const worker = new Worker(workerUrl)
        worker.addEventListener('message', (event) => {
          worker.terminate()
          resolve(event.data)
        }, { once: true })
        worker.addEventListener('error', (event) => {
          worker.terminate()
          reject(new Error(event.message || 'direct worker failed'))
        }, { once: true })
        worker.postMessage(candidate)
      })
      const workerOverflow = await directWorkerRequest(maximumRequest)
      const boundedSection = {
        startPoint: { x: 1, y: 1 },
        bendPoints: Array.from({ length: 6 }, () => ({ x: 1, y: 1 })),
        endPoint: { x: 2, y: 2 }
      }

      class MaximumShapeWorker {
        constructor() { this.listeners = new Map() }
        addEventListener(name, callback) { this.listeners.set(name, callback) }
        postMessage(candidate) {
          const response = {
            type: 'result',
            version: 1,
            requestId: candidate.requestId,
            generation: candidate.generation,
            nodes: candidate.nodes.map((node) => ({ id: node.id, x: 1, y: 1, width: node.width, height: node.height })),
            edges: candidate.edges.map((edge) => ({ id: edge.id, sections: [boundedSection] })),
            diagnostics: []
          }
          queueMicrotask(() => this.listeners.get('message')?.({ data: response }))
        }
        terminate() {}
      }

      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine, WorkerConstructor: MaximumShapeWorker })
      const startedAt = performance.now()
      const boundedResponse = await client.layout(maximumRequest)
      const elapsed = performance.now() - startedAt
      client.dispose()

      class OverBudgetShapeWorker {
        constructor() { this.listeners = new Map() }
        addEventListener(name, callback) { this.listeners.set(name, callback) }
        postMessage(candidate) {
          const response = {
            type: 'result',
            version: 1,
            requestId: candidate.requestId,
            generation: candidate.generation,
            nodes: candidate.nodes.map((node) => ({ id: node.id, x: 1, y: 1, width: node.width, height: node.height })),
            edges: candidate.edges.map((edge, index) => ({
              id: edge.id,
              sections: [{ ...boundedSection, bendPoints: Array.from({ length: index === candidate.edges.length - 1 ? 7 : 6 }, () => ({ x: 1, y: 1 })) }]
            })),
            diagnostics: []
          }
          queueMicrotask(() => this.listeners.get('message')?.({ data: response }))
        }
        terminate() {}
      }

      const overBudgetClient = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine, WorkerConstructor: OverBudgetShapeWorker })
      const overBudgetResponse = await overBudgetClient.layout(maximumRequest)
      overBudgetClient.dispose()
      return { workerOverflow, boundedResponse, overBudgetResponse, elapsed }
    }, { urls, request: layoutRequest(2, { generation: 19 }) })

    expect(result.workerOverflow).toMatchObject({ type: 'error', error: { code: 'layout_overflow' } })
    expect(result.boundedResponse).toMatchObject({ type: 'result', requestId: 'request_19_100', generation: 19 })
    expect(result.boundedResponse.nodes).toHaveLength(100)
    expect(result.boundedResponse.edges).toHaveLength(1_000)
    expect(result.boundedResponse.edges.every((edge) => edge.sections[0].bendPoints.length === 6)).toBe(true)
    expect(result.overBudgetResponse).toMatchObject({ type: 'error', error: { code: 'malformed_response' } })
    expect(result.elapsed).toBeLessThan(1_000)
    expect(pageErrors).toEqual([])
  } finally {
    await context.close()
  }
})

test('worker and client reject legal geometry that exceeds the response byte cap', async ({ browser }) => {
  const urls = await layoutAssetUrls()
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()
  const pageErrors = []
  page.on('pageerror', (error) => pageErrors.push(error.message))

  const byteOverflowEngine = `self.onmessage = ({ data }) => {
    if (data.cmd === 'register') { self.postMessage({ id: data.id, data: {} }); return; }
    const point = { x: 4094.999, y: 4094.999 };
    const section = { startPoint: point, bendPoints: Array.from({ length: 6 }, () => point), endPoint: point };
    self.postMessage({ id: data.id, data: {
      children: data.graph.children.map((node) => ({ id: node.id, x: point.x, y: point.y })),
      edges: data.graph.edges.map((edge) => ({ id: edge.id, sections: [section] }))
    } });
  };`

  try {
    await context.route(urls.engine, (route) => route.fulfill({ contentType: 'application/javascript', body: byteOverflowEngine }))
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const workerUrl = `${payload.urls.worker}?engine=${encodeURIComponent(payload.urls.engine)}`
      const maximumRequest = {
        ...payload.request,
        requestId: 'request_20_100',
        generation: 20,
        constraints: { lanes: [{ index: 0 }], phases: [{ index: 0 }] },
        nodes: Array.from({ length: 100 }, (_, index) => ({ id: `node_${index}`, width: 1, height: 1, lane: 0, phase: 0 })),
        edges: Array.from({ length: 1_000 }, (_, index) => ({ id: `edge_${index}`, source: 'node_0', target: 'node_1' }))
      }
      const directWorkerRequest = (candidate) => new Promise((resolve, reject) => {
        const worker = new Worker(workerUrl)
        worker.addEventListener('message', (event) => {
          worker.terminate()
          resolve(event.data)
        }, { once: true })
        worker.addEventListener('error', (event) => {
          worker.terminate()
          reject(new Error(event.message || 'direct worker failed'))
        }, { once: true })
        worker.postMessage(candidate)
      })
      const workerOverflow = await directWorkerRequest(maximumRequest)
      const byteCapPoint = { x: 4095.999, y: 4095.999 }
      const byteCapSection = {
        startPoint: byteCapPoint,
        bendPoints: Array.from({ length: 6 }, () => byteCapPoint),
        endPoint: byteCapPoint
      }
      const oversizedResponseFor = (candidate) => ({
        type: 'result',
        version: 1,
        requestId: candidate.requestId,
        generation: candidate.generation,
        nodes: candidate.nodes.map((node) => ({ id: node.id, x: byteCapPoint.x, y: byteCapPoint.y, width: node.width, height: node.height })),
        edges: candidate.edges.map((edge) => ({ id: edge.id, sections: [byteCapSection] })),
        diagnostics: []
      })

      class ByteOverflowWorker {
        constructor() { this.listeners = new Map() }
        addEventListener(name, callback) { this.listeners.set(name, callback) }
        postMessage(candidate) {
          queueMicrotask(() => this.listeners.get('message')?.({ data: oversizedResponseFor(candidate) }))
        }
        terminate() {}
      }

      const oversizedResponse = oversizedResponseFor(maximumRequest)
      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine, WorkerConstructor: ByteOverflowWorker })
      const clientOverflow = await client.layout(maximumRequest)
      client.dispose()
      return {
        workerOverflow,
        clientOverflow,
        responseBytes: new TextEncoder().encode(JSON.stringify(oversizedResponse)).byteLength,
        routePoints: oversizedResponse.edges.length * (oversizedResponse.edges[0].sections[0].bendPoints.length + 2)
      }
    }, { urls, request: layoutRequest(2, { generation: 20 }) })

    expect(result.routePoints).toBe(8_000)
    expect(result.responseBytes).toBeGreaterThan(256 * 1024)
    expect(result.workerOverflow).toMatchObject({ type: 'error', error: { code: 'layout_overflow' } })
    expect(result.clientOverflow).toMatchObject({ type: 'error', error: { code: 'malformed_response' } })
    expect(pageErrors).toEqual([])
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

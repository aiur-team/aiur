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
    requestId: 'request_7_4',
    generation: 7,
    constraints: {
      lanes: [{ index: 0 }, { index: 1 }],
      phases: [{ index: 0 }, { index: 1 }]
    },
    nodes: [
      { id: 'node_0', width: 120, height: 48, lane: 0, phase: 0 },
      { id: 'node_1', width: 120, height: 48, lane: 1, phase: 0 },
      { id: 'node_2', width: 120, height: 48, lane: 0, phase: 1 },
      { id: 'node_3', width: 120, height: 48, lane: 1, phase: 1 }
    ],
    edges: [
      { id: 'edge_0', source: 'node_0', target: 'node_2' },
      { id: 'edge_1', source: 'node_1', target: 'node_3' }
    ],
    options: { direction: 'RIGHT', edgeRouting: 'ORTHOGONAL', randomSeed: 1, thoroughness: 1, considerModelOrder: true }
  }
  const disconnectedRequest = {
    ...multipleRootRequest,
    requestId: 'request_8_4',
    generation: 8,
    edges: []
  }

  try {
    await openFixture(page)

    const result = await page.evaluate(async (payload) => {
      const { createLayoutWorkerClient } = await import(payload.urls.client)
      const client = createLayoutWorkerClient({ workerUrl: payload.urls.worker, engineUrl: payload.urls.engine })
      const first = await client.layout(payload.multipleRootRequest)
      const second = await client.layout(payload.multipleRootRequest)
      const disconnected = await client.layout(payload.disconnectedRequest)
      client.dispose()
      return { first, second, disconnected }
    }, { urls, multipleRootRequest, disconnectedRequest })

    for (const layout of [result.first, result.disconnected]) {
      const positions = new Map(layout.nodes.map((node) => [node.id, node]))
      const phaseZero = ['node_0', 'node_1'].map((id) => positions.get(id).x)
      const phaseOne = ['node_2', 'node_3'].map((id) => positions.get(id).x)
      const laneZero = ['node_0', 'node_2'].map((id) => positions.get(id).y)
      const laneOne = ['node_1', 'node_3'].map((id) => positions.get(id).y)

      expect(layout.type).toBe('result')
      expect(Math.max(...phaseZero)).toBeLessThan(Math.min(...phaseOne))
      expect(Math.max(...laneZero)).toBeLessThan(Math.min(...laneOne))
    }
    expect(result.second).toEqual(result.first)
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

      return { malformed, oversized, credentialShaped, directMalformed, directOversized, directInvalidConstraint, directEngineQuery, directEngineHash, directDuplicateEngine, directExtraParameter, stale, preflight, invalidPosts, assetUrlConstructions, invalidAssetUrls, unsupported, timeout, retry, constructions, malformedResponse, malformedGeometry, staleResponse, lateTimeout, lateRecoveryResult, lateWorkers: lateWorkers.length, firstDuplicate, secondDuplicate, engineFailure }
    }, { urls, request: layoutRequest(20, { generation: 9, cycle: true }) })

    expect(result.malformed).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.malformed.error.message).not.toContain('must-not-cross-worker-boundary')
    expect(result.oversized).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.credentialShaped).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(JSON.stringify(result.credentialShaped)).not.toContain('ghp_')
    expect(result.directMalformed).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.directOversized).toMatchObject({ type: 'error', requestId: 'request_12_101', generation: 12, error: { code: 'invalid_request' } })
    expect(result.directInvalidConstraint).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
    expect(result.directEngineQuery).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'engine_unavailable' } })
    expect(result.directEngineHash).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'engine_unavailable' } })
    expect(result.directDuplicateEngine).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'engine_unavailable' } })
    expect(result.directExtraParameter).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'engine_unavailable' } })
    expect(JSON.stringify(result.directMalformed)).not.toContain('ghp_')
    expect(JSON.stringify(result.directOversized).length).toBeLessThan(256)
    expect(result.preflight).toMatchObject({ type: 'error', requestId: 'request_9_20', generation: 9, error: { code: 'invalid_request' } })
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

import { expect, test } from '@playwright/test'
import { openFixture } from '../support/browser-helpers.mjs'
import { dashboardCredentials, layoutAssetUrls, layoutRequest } from '../support/layout-worker.mjs'

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

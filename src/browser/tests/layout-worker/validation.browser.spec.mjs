import { expect, test } from '@playwright/test'
import { openFixture } from '../support/browser-helpers.mjs'
import { dashboardCredentials, layoutAssetUrls, layoutRequest } from '../support/layout-worker.mjs'

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

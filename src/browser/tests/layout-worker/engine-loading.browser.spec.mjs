import { expect, test } from '@playwright/test'
import { openFixture } from '../support/browser-helpers.mjs'
import { dashboardCredentials, layoutAssetUrls, layoutRequest } from '../support/layout-worker.mjs'

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

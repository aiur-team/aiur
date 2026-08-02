import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openFixture } from './support/browser-helpers.mjs'

// The Build Order route no longer mounts the DOM/SVG layout adapter — it
// renders a synchronous CSS grid via the BuildOrderGrid hook, and that grid's
// rendering, interaction, performance, and responsive behaviour are covered by
// the build-order-* specs. The vendored DOM/SVG layout modules are still
// shipped, so these specs keep exercising their protocol/measurement/validation
// contract directly (imported as modules), independent of any route mounting.

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
        nodes: [{ id: 'node_0', x: 65_536, y: 30, width: 4096, height: 40 }]
      }
      // The Build Order route no longer mounts the DOM/SVG adapter (it renders a
      // synchronous CSS grid), so drive measureLayout with a synthetic element
      // that lacks the adapter's required measurement markup: it must return null
      // rather than measure a malformed root.
      const root = document.createElement('div')
      root.id = 'synthetic-layout-root'
      document.body.appendChild(root)
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

// Regression for #1270: the real Build Order graph (#1084 — 54 nodes, 106
// edges, 8 phase partitions) lays out to a canvas thousands of pixels wide, so
// the worker/client protocol now emits node and edge-point coordinates in the
// 5,000-15,000 range. Protocol-level validation independently bounded EVERY
// absolute coordinate (validCoordinate) and node extent (validExtent) against
// MAX_DIMENSION (4096) — a value meant only for a single card's width/height —
// so validateLayoutResult rejected the geometry and the adapter fell back to
// document flow with `malformed_geometry` (zero edges). The prior worker/client
// fix never exercised this validateLayoutResult/geometryBounds layer, which is
// why the fallback survived. This drives a large-coordinate result directly
// through the protocol validators and asserts acceptance (plus a canvas beyond
// the old bound), while confirming the raised guard still rejects coordinates
// past the coordinate-space cap.
test('protocol validation accepts real #1084-scale coordinates and still guards the coordinate-space cap', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(async () => {
      const { validateLayoutResult, geometryBounds, MAX_COORDINATE } = await import('/aiur-dom-svg-layout/protocol.js')

      const NODE_COUNT = 54
      const CARD_W = 260
      const CARD_H = 150
      // Nodes fan out across a canvas that is several thousand px wide/tall,
      // mirroring #1084's layered geometry — every coordinate is far past the
      // old 4096 bound but well inside the raised coordinate-space cap.
      const requestNodes = Array.from({ length: NODE_COUNT }, (_, index) => ({ id: `node_${index}`, width: CARD_W, height: CARD_H }))
      const responseNodes = requestNodes.map((node, index) => ({
        ...node,
        x: 400 + (index % 9) * 1_600,
        y: 400 + Math.floor(index / 9) * 900
      }))
      const requestEdges = []
      const responseEdges = []
      for (let index = 1; index < NODE_COUNT; index += 1) {
        requestEdges.push({ id: `edge_${requestEdges.length}`, source: `node_${index - 1}`, target: `node_${index}` })
        const source = responseNodes[index - 1]
        const target = responseNodes[index]
        responseEdges.push({
          id: `edge_${responseEdges.length}`,
          sections: [{
            startPoint: { x: source.x + CARD_W, y: source.y + CARD_H / 2 },
            bendPoints: [{ x: target.x - 20, y: source.y + CARD_H / 2 }],
            endPoint: { x: target.x, y: target.y + CARD_H / 2 }
          }]
        })
      }

      const request = { requestId: `request_30_${NODE_COUNT}`, generation: 30, nodes: requestNodes, edges: requestEdges }
      const response = { type: 'result', version: 1, requestId: request.requestId, generation: 30, nodes: responseNodes, edges: responseEdges }

      const maxCoordinate = Math.max(
        ...responseNodes.flatMap((node) => [node.x, node.y]),
        ...responseEdges.flatMap((edge) => edge.sections.flatMap((section) => [section.startPoint, ...section.bendPoints, section.endPoint].flatMap((point) => [point.x, point.y])))
      )

      const overCap = {
        ...response,
        nodes: [{ ...responseNodes[0], x: MAX_COORDINATE + 1 }, ...responseNodes.slice(1)]
      }
      const bounds = geometryBounds(response)

      return {
        accepted: validateLayoutResult(response, request),
        rejectedBeyondCap: validateLayoutResult(overCap, request),
        maxCoordinate,
        boundsWidth: bounds?.width ?? null,
        boundsHeight: bounds?.height ?? null,
        maxCoordinateConstant: MAX_COORDINATE
      }
    })

    // The #1084-scale geometry genuinely exceeds the former 4096 bound, so this
    // pins the regression rather than re-testing an already-bounded graph.
    expect(result.maxCoordinate).toBeGreaterThan(4_096)
    // Validation accepts it (adapter reaches is-layout-ready, edges render)
    // instead of collapsing to the `malformed_geometry` fallback.
    expect(result.accepted).toBe(true)
    // geometryBounds returns a real canvas larger than the old bound.
    expect(result.boundsWidth).toBeGreaterThan(4_096)
    expect(result.boundsHeight).toBeGreaterThan(0)
    // The bound is still a genuine guard: coordinates past the coordinate-space
    // cap are rejected, they are only sized for the real dataset now.
    expect(result.rejectedBeyondCap).toBe(false)
    expect(result.maxCoordinateConstant).toBe(65_536)
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

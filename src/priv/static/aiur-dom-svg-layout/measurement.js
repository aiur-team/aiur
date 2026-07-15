import {
  MAX_EDGES,
  MAX_NODES,
  assetPaths,
  boundedText,
  contextDimension,
  constraintIndexes,
  edgeState,
  measuredDimension,
  nonNegativeInteger,
  positiveInteger,
  validAssetUrl,
  validMeasurement
} from "./protocol.js"

const visualProperties = ["--bo-layout-x", "--bo-layout-y", "--bo-layout-width", "--bo-layout-height"]

export function layoutAssetUrls(element) {
  const clientUrl = validAssetUrl(element.dataset.layoutClientUrl, assetPaths.client)
  const workerUrl = validAssetUrl(element.dataset.layoutWorkerUrl, assetPaths.worker)
  const engineUrl = validAssetUrl(element.dataset.layoutEngineUrl, assetPaths.engine)

  return clientUrl && workerUrl && engineUrl
    ? { clientUrl, workerUrl, engineUrl }
    : null
}

export function measureLayout(element, { clientEpoch, layoutGeneration, measurementVersion }) {
  const root = readRootContext(element, measurementVersion)
  if (!root) return null

  return withNaturalCardMeasurements(element, () => {
    const nodeElements = Array.from(element.querySelectorAll("[data-layout-node]"))
    if (nodeElements.length === 0 || nodeElements.length > MAX_NODES) return null

    const nodeBySemanticId = new Map()
    const workerIdBySemanticId = new Map()
    const cardsByWorkerId = new Map()
    const nodes = []

    for (const [index, card] of nodeElements.entries()) {
      const semanticId = boundedText(card.dataset.layoutNodeId)
      const header = card.querySelector("[data-layout-card-header]")
      const lane = nonNegativeInteger(card.dataset.layoutLane)
      const phase = nonNegativeInteger(card.dataset.layoutPhase)
      const cardRect = card.getBoundingClientRect()
      const headerRect = header?.getBoundingClientRect()

      if (!semanticId || nodeBySemanticId.has(semanticId) || !headerRect || !validMeasurement(cardRect) || !validMeasurement(headerRect) || lane === null || phase === null) return null

      const workerId = `node_${index}`
      nodeBySemanticId.set(semanticId, card)
      workerIdBySemanticId.set(semanticId, workerId)
      cardsByWorkerId.set(workerId, card)
      nodes.push({ id: workerId, width: measuredDimension(cardRect.width), height: measuredDimension(cardRect.height), lane, phase })
    }

    const edgeElements = Array.from(element.querySelectorAll("[data-layout-edge]"))
    if (edgeElements.length > MAX_EDGES) return null

    const edges = []
    const edgeRecords = new Map()

    for (const edgeElement of edgeElements) {
      const source = boundedText(edgeElement.dataset.layoutEdgeSource)
      const target = boundedText(edgeElement.dataset.layoutEdgeTarget)
      const state = edgeState(edgeElement.dataset.layoutEdgeState)

      if (!source || !target || !state || !workerIdBySemanticId.has(source) || !workerIdBySemanticId.has(target)) continue

      const workerId = `edge_${edges.length}`
      edges.push({ id: workerId, source: workerIdBySemanticId.get(source), target: workerIdBySemanticId.get(target) })
      edgeRecords.set(workerId, { element: edgeElement, state })
    }

    const context = { ...root, clientEpoch, layoutGeneration }
    const request = {
      type: "layout",
      version: 1,
      requestId: `request_${layoutGeneration}_${nodes.length}`,
      generation: layoutGeneration,
      nodes,
      edges,
      constraints: {
        lanes: constraintIndexes(nodes, "lane"),
        phases: constraintIndexes(nodes, "phase")
      },
      options: {
        direction: "RIGHT",
        edgeRouting: "ORTHOGONAL",
        randomSeed: 1,
        thoroughness: 1,
        considerModelOrder: true,
        favorStraightEdges: true
      }
    }

    return { cardsByWorkerId, context, edgeRecords, request }
  })
}

export function readRootContext(element, measurementVersion) {
  const rootId = boundedText(element.dataset.layoutRootId)
  const providerGeneration = positiveInteger(element.dataset.layoutProviderGeneration)
  const domGeneration = positiveInteger(element.dataset.layoutDomGeneration)
  const rect = element.getBoundingClientRect()
  const windowWidth = contextDimension(window.innerWidth)
  const windowHeight = contextDimension(window.innerHeight)
  const viewportWidth = contextDimension(Math.min(rect.width, window.innerWidth))
  const viewportHeight = contextDimension(Math.min(rect.height, window.innerHeight))

  if (!rootId || providerGeneration === null || domGeneration === null || !viewportWidth || !viewportHeight || !windowWidth || !windowHeight) return null

  return { rootId, providerGeneration, domGeneration, measurementVersion, viewportWidth, viewportHeight, windowWidth, windowHeight }
}

function withNaturalCardMeasurements(element, callback) {
  const cards = Array.from(element.querySelectorAll("[data-layout-node]"))
  const cardsSurface = element.querySelector("[data-layout-cards]")
  const wasReady = element.classList.contains("is-layout-ready")
  const cardStyles = cards.map((card) => ({ card, properties: snapshotProperties(card, visualProperties) }))
  const surfaceStyles = cardsSurface ? snapshotProperties(cardsSurface, ["min-width", "min-height"]) : []

  element.classList.remove("is-layout-ready")
  cardStyles.forEach(({ card }) => visualProperties.forEach((property) => card.style.removeProperty(property)))
  cardsSurface?.style.removeProperty("min-width")
  cardsSurface?.style.removeProperty("min-height")

  try {
    return callback()
  } finally {
    cardStyles.forEach(({ card, properties }) => restoreProperties(card, properties))
    if (cardsSurface) restoreProperties(cardsSurface, surfaceStyles)
    if (wasReady) element.classList.add("is-layout-ready")
  }
}

function snapshotProperties(element, properties) {
  return properties.map((property) => ({ property, value: element.style.getPropertyValue(property), priority: element.style.getPropertyPriority(property) }))
}

function restoreProperties(element, properties) {
  properties.forEach(({ property, value, priority }) => {
    if (value) element.style.setProperty(property, value, priority)
    else element.style.removeProperty(property)
  })
}

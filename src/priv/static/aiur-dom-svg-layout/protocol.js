export const MAX_DIMENSION = 4_096
export const MAX_NODES = 100
export const MAX_EDGES = 1_000
export const MAX_SECTIONS = 16
export const MAX_BEND_POINTS = 62
export const MAX_ROUTE_POINTS = 8_000
export const LAYOUT_PROTOCOL_VERSION = 1
export const EDGE_STATES = new Set(["cleared", "blocking", "terminal_unsatisfied", "unknown", "cyclic"])
export const assetPaths = {
  client: /^\/vendor\/layout\/client-v1\/[a-f0-9]{64}\/aiur-layout-client\.js$/,
  worker: /^\/vendor\/layout\/worker-v1\/[a-f0-9]{64}\/aiur-layout-worker\.js$/,
  engine: /^\/vendor\/layout\/elk-0\.11\.1\/[a-f0-9]{64}\/elk-worker\.min\.js$/
}
export const healthMessages = {
  fallback: "Using readable document-flow layout.",
  measuring: "Calculating graph layout.",
  ready: "Graph layout is ready."
}

export function matchesLayoutContext(current, expected) {
  return Boolean(current && expected) &&
    current.rootId === expected.rootId &&
    current.providerGeneration === expected.providerGeneration &&
    current.domGeneration === expected.domGeneration &&
    current.measurementVersion === expected.measurementVersion &&
    current.viewportWidth === expected.viewportWidth &&
    current.viewportHeight === expected.viewportHeight &&
    current.windowWidth === expected.windowWidth &&
    current.windowHeight === expected.windowHeight
}

export function validateLayoutResult(response, request) {
  if (!response || response.version !== LAYOUT_PROTOCOL_VERSION || response.requestId !== request.requestId || response.generation !== request.generation) return false
  if (response.type === "error") return typeof response.error?.code === "string"
  if (response.type !== "result" || !Array.isArray(response.nodes) || !Array.isArray(response.edges)) return false
  if (response.nodes.length > MAX_NODES || response.edges.length > MAX_EDGES || response.nodes.length !== request.nodes.length || response.edges.length !== request.edges.length) return false

  const requestedNodes = new Map(request.nodes.map((node) => [node.id, node]))
  const requestedEdges = new Set(request.edges.map((edge) => edge.id))
  const returnedNodes = new Set()
  const returnedEdges = new Set()

  for (const node of response.nodes) {
    const requested = requestedNodes.get(node?.id)
    if (!requested || returnedNodes.has(node.id) || !validNode(node, requested)) return false
    returnedNodes.add(node.id)
  }

  let routePointCount = 0
  for (const edge of response.edges) {
    if (!requestedEdges.has(edge?.id) || returnedEdges.has(edge.id) || !Array.isArray(edge.sections) || edge.sections.length === 0 || edge.sections.length > MAX_SECTIONS) return false
    if (!edge.sections.every(validSection)) return false
    routePointCount += edge.sections.reduce((count, section) => count + section.bendPoints.length + 2, 0)
    if (routePointCount > MAX_ROUTE_POINTS) return false
    returnedEdges.add(edge.id)
  }

  return returnedNodes.size === requestedNodes.size && returnedEdges.size === requestedEdges.size
}

export function geometryBounds(response) {
  const points = []
  response.nodes.forEach((node) => points.push({ x: node.x + node.width, y: node.y + node.height }))
  response.edges.forEach((edge) => edge.sections.forEach((section) => points.push(section.startPoint, ...section.bendPoints, section.endPoint)))

  if (points.length === 0 || !points.every(validPoint)) return null

  const width = Math.ceil(Math.max(...points.map((point) => point.x)))
  const height = Math.ceil(Math.max(...points.map((point) => point.y)))
  return validCoordinate(width) && validCoordinate(height) ? { width, height } : null
}

export function constraintIndexes(nodes, key) {
  return [...new Set(nodes.map((node) => node[key]))].sort((left, right) => left - right).map((index) => ({ index }))
}

export function validAssetUrl(value, pathPattern) {
  if (typeof value !== "string") return null

  try {
    const url = new URL(value, window.location.origin)
    if (url.origin !== window.location.origin || url.username || url.password || url.search || url.hash || !pathPattern.test(url.pathname)) return null
    return url.pathname
  } catch {
    return null
  }
}

export function validMeasurement(rect) {
  return Boolean(rect) && measuredDimension(rect.width) && measuredDimension(rect.height)
}

export function measuredDimension(value) {
  const rounded = Math.round(Number(value))
  return Number.isFinite(rounded) && rounded >= 1 && rounded <= MAX_DIMENSION ? rounded : null
}

export function boundedText(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 160 ? value : null
}

export function edgeState(value) {
  return EDGE_STATES.has(value) ? value : null
}

export function nonNegativeInteger(value) {
  const parsed = Number(value)
  return Number.isInteger(parsed) && parsed >= 0 && parsed < MAX_NODES ? parsed : null
}

export function positiveInteger(value) {
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null
}

export function safeCode(value) {
  return typeof value === "string" ? value.replace(/[^a-z0-9_-]/gi, "_").slice(0, 64) : "layout_failed"
}

export function errorCode(error, fallback) {
  return safeCode(error?.message || error?.code || fallback)
}

export function now() {
  return typeof performance?.now === "function" ? performance.now() : Date.now()
}

function validNode(node, requested) {
  return validCoordinate(node.x) &&
    validCoordinate(node.y) &&
    node.width === requested.width &&
    node.height === requested.height &&
    validExtent(node.x, node.width) &&
    validExtent(node.y, node.height)
}

function validSection(section) {
  return section &&
    validPoint(section.startPoint) &&
    Array.isArray(section.bendPoints) &&
    section.bendPoints.length <= MAX_BEND_POINTS &&
    section.bendPoints.every(validPoint) &&
    validPoint(section.endPoint)
}

function validPoint(point) {
  return point && validCoordinate(point.x) && validCoordinate(point.y)
}

function validCoordinate(value) {
  return Number.isFinite(value) && value >= 1 && value <= MAX_DIMENSION
}

function validExtent(origin, dimension) {
  return Number.isFinite(dimension) && dimension >= 1 && origin + dimension <= MAX_DIMENSION
}

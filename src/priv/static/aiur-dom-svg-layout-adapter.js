const MAX_DIMENSION = 4_096
const MAX_NODES = 100
const MAX_EDGES = 1_000
const MAX_SECTIONS = 16
const MAX_BEND_POINTS = 62
const MAX_ROUTE_POINTS = 8_000
const LAYOUT_PROTOCOL_VERSION = 1
const EDGE_STATES = new Set(["cleared", "blocking", "terminal_unsatisfied", "unknown", "cyclic"])
const assetPaths = {
  client: /^\/vendor\/layout\/client-v1\/[a-f0-9]{64}\/aiur-layout-client\.js$/,
  worker: /^\/vendor\/layout\/worker-v1\/[a-f0-9]{64}\/aiur-layout-worker\.js$/,
  engine: /^\/vendor\/layout\/elk-0\.11\.1\/[a-f0-9]{64}\/elk-worker\.min\.js$/
}
const healthMessages = {
  fallback: "Using readable document-flow layout.",
  measuring: "Calculating graph layout.",
  ready: "Graph layout is ready."
}

let hookInstance = 0

export function createDomSvgLayoutHook(options = {}) {
  return {
    mounted() {
      this.__domSvgLayoutAdapter?.destroy()
      this.__domSvgLayoutAdapter = new DomSvgLayoutAdapter(this.el, options)
      this.__domSvgLayoutAdapter.mount()
    },
    beforeUpdate() {
      this.__domSvgLayoutAdapter?.invalidate()
    },
    updated() {
      this.__domSvgLayoutAdapter?.updated()
    },
    destroyed() {
      this.__domSvgLayoutAdapter?.destroy()
      this.__domSvgLayoutAdapter = null
    }
  }
}

class DomSvgLayoutAdapter {
  constructor(element, options) {
    this.element = element
    this.options = options
    this.destroyed = false
    this.layoutGeneration = 0
    this.measurementVersion = 0
    this.scheduled = false
    this.client = null
    this.clientPromise = null
    this.clientAssetKey = null
    this.clientEpoch = 0
    this.observer = null
    this.fontsReady = null
    this.onWindowResize = () => this.scheduleLayout()
  }

  mount() {
    this.hookInstance = String(++hookInstance)
    this.hookCount = Number(this.element.dataset.layoutHookCount || 0) + 1
    this.restoreHookMarkers()

    this.installObservers()
    this.configureClient()

    this.scheduleLayout()
  }

  updated() {
    this.restoreHookMarkers()
    this.scheduleLayout()
  }

  invalidate() {
    this.measurementVersion += 1
    this.clearVisualLayout()
  }

  scheduleLayout() {
    if (this.destroyed || this.scheduled) return

    this.scheduled = true
    queueMicrotask(() => {
      this.scheduled = false
      this.requestLayout()
    })
  }

  destroy() {
    this.destroyed = true
    this.clientEpoch += 1
    this.observer?.disconnect()
    this.observer = null
    window.removeEventListener("resize", this.onWindowResize)
    this.client?.dispose?.()
    this.client = null
  }

  installObservers() {
    if (typeof ResizeObserver === "function") {
      this.observer = new ResizeObserver(() => this.scheduleLayout())
      this.observer.observe(this.element)
    }

    window.addEventListener("resize", this.onWindowResize)

    const fonts = document.fonts
    if (fonts?.ready && typeof fonts.ready.then === "function") {
      this.fontsReady = fonts.ready.then(() => this.scheduleLayout()).catch(() => {})
    }
  }

  restoreHookMarkers() {
    this.element.dataset.layoutHookInstance = this.hookInstance
    this.element.dataset.layoutHookCount = String(this.hookCount)
  }

  async createClient(urls) {
    if (!urls) throw new Error("asset_url_invalid")

    if (typeof this.options.clientFactory === "function") {
      return this.options.clientFactory(urls)
    }

    const module = await import(urls.clientUrl)
    return module.createLayoutWorkerClient({ workerUrl: urls.workerUrl, engineUrl: urls.engineUrl })
  }

  assetUrls() {
    const clientUrl = validAssetUrl(this.element.dataset.layoutClientUrl, assetPaths.client)
    const workerUrl = validAssetUrl(this.element.dataset.layoutWorkerUrl, assetPaths.worker)
    const engineUrl = validAssetUrl(this.element.dataset.layoutEngineUrl, assetPaths.engine)

    return clientUrl && workerUrl && engineUrl
      ? { clientUrl, workerUrl, engineUrl }
      : null
  }

  requestLayout() {
    if (this.destroyed) return

    this.configureClient()
    const clientEpoch = this.clientEpoch

    this.clientPromise?.then((client) => {
      if (!client || this.destroyed || clientEpoch !== this.clientEpoch) return

      const measured = this.measure()
      if (!measured) return this.fallback("measurement_invalid")

      const request = measured.request
      const context = measured.context
      const startedAt = now()

      this.setHealth("measuring")
      client.layout(request).then((response) => {
        if (!this.canApply(context, request)) return this.discard(response)

        if (!validateLayoutResult(response, request)) return this.fallback("malformed_geometry")
        if (response.type === "error") return this.fallback(response.error?.code || "worker_failed")

        this.apply(response, measured, startedAt)
      }).catch((error) => {
        if (this.canApply(context, request)) this.fallback(errorCode(error, "worker_failed"))
      })
    })
  }

  configureClient() {
    const urls = this.assetUrls()
    const assetKey = urls ? `${urls.clientUrl}\u0000${urls.workerUrl}\u0000${urls.engineUrl}` : ""
    if (assetKey === this.clientAssetKey && this.clientPromise) return

    this.client?.dispose?.()
    this.client = null
    this.clientAssetKey = assetKey
    const clientEpoch = ++this.clientEpoch
    this.clientPromise = this.createClient(urls)
      .then((client) => {
        if (this.destroyed || clientEpoch !== this.clientEpoch) {
          client?.dispose?.()
          return null
        }

        this.client = client
        return client
      })
      .catch((error) => {
        if (!this.destroyed && clientEpoch === this.clientEpoch) this.fallback(errorCode(error, "worker_start_failed"))
        return null
      })
  }

  measure() {
    const root = readRootContext(this.element, this.measurementVersion + 1)
    if (!root) return null

    const nodeElements = Array.from(this.element.querySelectorAll("[data-layout-node]"))
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

      if (!semanticId || nodeBySemanticId.has(semanticId) || !headerRect || !validMeasurement(cardRect) || !validMeasurement(headerRect) || lane === null || phase === null) {
        return null
      }

      const workerId = `node_${index}`
      nodeBySemanticId.set(semanticId, card)
      workerIdBySemanticId.set(semanticId, workerId)
      cardsByWorkerId.set(workerId, card)
      nodes.push({ id: workerId, width: measuredDimension(cardRect.width), height: measuredDimension(cardRect.height), lane, phase })
    }

    const edgeElements = Array.from(this.element.querySelectorAll("[data-layout-edge]"))
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

    const generation = ++this.layoutGeneration
    const context = {
      ...root,
      measurementVersion: ++this.measurementVersion,
      layoutGeneration: generation,
      clientEpoch: this.clientEpoch
    }
    const request = {
      type: "layout",
      version: 1,
      requestId: `request_${generation}_${nodes.length}`,
      generation,
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
  }

  canApply(context, request) {
    return !this.destroyed &&
      this.element.dataset.layoutHookInstance === this.hookInstance &&
      context.clientEpoch === this.clientEpoch &&
      request.generation === context.layoutGeneration &&
      matchesLayoutContext(readRootContext(this.element, this.measurementVersion), context)
  }

  discard(response) {
    this.element.dataset.layoutDiscardedResponse = response?.type === "error" ? "error" : "stale"
  }

  apply(response, measured, startedAt) {
    const cards = this.element.querySelector("[data-layout-cards]")
    const svg = this.element.querySelector("[data-layout-edges]")
    if (!cards || !svg) return this.fallback("missing_surface")

    const geometry = geometryBounds(response)
    if (!geometry) return this.fallback("malformed_geometry")

    for (const node of response.nodes) {
      const card = measured.cardsByWorkerId.get(node.id)
      if (!card) return this.fallback("malformed_geometry")

      card.style.setProperty("--bo-layout-x", `${node.x}px`)
      card.style.setProperty("--bo-layout-y", `${node.y}px`)
      card.style.setProperty("--bo-layout-width", `${node.width}px`)
      card.style.setProperty("--bo-layout-height", `${node.height}px`)
    }

    cards.style.minWidth = `${geometry.width}px`
    cards.style.minHeight = `${geometry.height}px`
    drawEdges(svg, response.edges, measured.edgeRecords, geometry, this.element.dataset.layoutHookInstance)

    this.element.classList.remove("is-layout-fallback")
    this.element.classList.add("is-layout-ready")
    this.element.dataset.layoutDiscardedResponse = ""
    this.setHealth("ready", now() - startedAt)
  }

  fallback(reason) {
    if (this.destroyed) return

    this.clearVisualLayout()
    this.element.classList.remove("is-layout-ready")
    this.element.classList.add("is-layout-fallback")
    this.setHealth("fallback", undefined, reason)
  }

  clearVisualLayout() {
    this.element.querySelectorAll("[data-layout-node]").forEach((card) => {
      card.style.removeProperty("--bo-layout-x")
      card.style.removeProperty("--bo-layout-y")
      card.style.removeProperty("--bo-layout-width")
      card.style.removeProperty("--bo-layout-height")
    })

    const cards = this.element.querySelector("[data-layout-cards]")
    cards?.style.removeProperty("min-width")
    cards?.style.removeProperty("min-height")
    this.element.querySelector("[data-layout-edges]")?.replaceChildren()
  }

  setHealth(health, durationMs, reason) {
    const message = this.element.querySelector("[data-layout-health-message]")
    this.element.dataset.layoutHealth = health
    if (reason) this.element.dataset.layoutFailure = safeCode(reason)
    else delete this.element.dataset.layoutFailure
    if (message) message.textContent = healthMessages[health] || healthMessages.fallback

    this.element.dispatchEvent(new CustomEvent("aiur:layout-health", {
      bubbles: true,
      detail: {
        health,
        durationMs: Number.isFinite(durationMs) ? Math.round(durationMs) : null,
        reason: reason ? safeCode(reason) : null
      }
    }))
  }
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
    if (!requested || returnedNodes.has(node.id) || !validCoordinate(node.x) || !validCoordinate(node.y) || node.width !== requested.width || node.height !== requested.height) return false
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

function readRootContext(element, measurementVersion) {
  const rootId = boundedText(element.dataset.layoutRootId)
  const providerGeneration = positiveInteger(element.dataset.layoutProviderGeneration)
  const domGeneration = positiveInteger(element.dataset.layoutDomGeneration)
  const rect = element.getBoundingClientRect()
  const viewportWidth = measuredDimension(rect.width)
  const viewportHeight = measuredDimension(rect.height)
  const windowWidth = measuredDimension(window.innerWidth)
  const windowHeight = measuredDimension(window.innerHeight)

  if (!rootId || providerGeneration === null || domGeneration === null || !viewportWidth || !viewportHeight || !windowWidth || !windowHeight) return null

  return { rootId, providerGeneration, domGeneration, measurementVersion, viewportWidth, viewportHeight, windowWidth, windowHeight }
}

function drawEdges(svg, edges, edgeRecords, geometry, instance) {
  const namespace = "http://www.w3.org/2000/svg"
  const defs = document.createElementNS(namespace, "defs")
  const markers = new Map()

  for (const state of EDGE_STATES) {
    const markerId = `bo-layout-marker-${instance}-${state}`
    const marker = document.createElementNS(namespace, "marker")
    marker.setAttribute("id", markerId)
    marker.setAttribute("viewBox", "0 0 8 8")
    marker.setAttribute("refX", "7")
    marker.setAttribute("refY", "4")
    marker.setAttribute("markerWidth", "7")
    marker.setAttribute("markerHeight", "7")
    marker.setAttribute("orient", "auto")

    const arrow = document.createElementNS(namespace, "path")
    arrow.setAttribute("d", "M 0 0 L 8 4 L 0 8 z")
    arrow.setAttribute("class", `bo-layout-edge-marker is-${state}`)
    marker.append(arrow)
    defs.append(marker)
    markers.set(state, markerId)
  }

  const fragments = [defs]
  for (const edge of edges) {
    const record = edgeRecords.get(edge.id)
    if (!record) continue

    const path = document.createElementNS(namespace, "path")
    path.setAttribute("class", `bo-layout-edge is-${record.state}`)
    path.setAttribute("data-layout-edge-path", record.element.dataset.layoutEdgeId || "")
    path.setAttribute("d", edgePath(edge.sections))
    path.setAttribute("marker-end", `url(#${markers.get(record.state)})`)
    fragments.push(path)
  }

  svg.setAttribute("viewBox", `0 0 ${geometry.width} ${geometry.height}`)
  svg.setAttribute("width", String(geometry.width))
  svg.setAttribute("height", String(geometry.height))
  svg.replaceChildren(...fragments)
}

function edgePath(sections) {
  return sections.map((section) => {
    const points = [section.startPoint, ...section.bendPoints, section.endPoint]
    return points.map((point, index) => `${index === 0 ? "M" : "L"}${point.x} ${point.y}`).join(" ")
  }).join(" ")
}

function geometryBounds(response) {
  const points = []
  response.nodes.forEach((node) => points.push({ x: node.x + node.width, y: node.y + node.height }))
  response.edges.forEach((edge) => edge.sections.forEach((section) => points.push(section.startPoint, ...section.bendPoints, section.endPoint)))

  const width = Math.min(MAX_DIMENSION, Math.ceil(Math.max(1, ...points.map((point) => point.x))))
  const height = Math.min(MAX_DIMENSION, Math.ceil(Math.max(1, ...points.map((point) => point.y))))
  return validCoordinate(width) && validCoordinate(height) ? { width, height } : null
}

function constraintIndexes(nodes, key) {
  return [...new Set(nodes.map((node) => node[key]))].sort((left, right) => left - right).map((index) => ({ index }))
}

function validSection(section) {
  return section &&
    validPoint(section.startPoint) &&
    Array.isArray(section.bendPoints) &&
    section.bendPoints.length <= MAX_BEND_POINTS &&
    section.bendPoints.every(validPoint) &&
    validPoint(section.endPoint)
}

function validAssetUrl(value, pathPattern) {
  if (typeof value !== "string") return null

  try {
    const url = new URL(value, window.location.origin)
    if (url.origin !== window.location.origin || url.username || url.password || url.search || url.hash || !pathPattern.test(url.pathname)) return null
    return url.pathname
  } catch {
    return null
  }
}

function validPoint(point) {
  return point && validCoordinate(point.x) && validCoordinate(point.y)
}

function validMeasurement(rect) {
  return Boolean(rect) && measuredDimension(rect.width) && measuredDimension(rect.height)
}

function measuredDimension(value) {
  const rounded = Math.round(Number(value))
  return Number.isFinite(rounded) && rounded >= 1 && rounded <= MAX_DIMENSION ? rounded : null
}

function validCoordinate(value) {
  return Number.isFinite(value) && value >= 1 && value <= MAX_DIMENSION
}

function boundedText(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 160 ? value : null
}

function edgeState(value) {
  return EDGE_STATES.has(value) ? value : null
}

function nonNegativeInteger(value) {
  const parsed = Number(value)
  return Number.isInteger(parsed) && parsed >= 0 && parsed < MAX_NODES ? parsed : null
}

function positiveInteger(value) {
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null
}

function safeCode(value) {
  return typeof value === "string" ? value.replace(/[^a-z0-9_-]/gi, "_").slice(0, 64) : "layout_failed"
}

function errorCode(error, fallback) {
  return safeCode(error?.message || error?.code || fallback)
}

function now() {
  return typeof performance?.now === "function" ? performance.now() : Date.now()
}

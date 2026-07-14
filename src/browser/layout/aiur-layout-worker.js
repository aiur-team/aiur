const PROTOCOL_VERSION = 1
const MAX_REQUEST_BYTES = 256 * 1024
const MAX_NODES = 100
const MAX_EDGES = 1_000
const MAX_CONSTRAINTS = 100
const MAX_OPTIONS = 8
const MAX_SECTIONS = 16
const MAX_POINTS = 64
const MAX_DIAGNOSTICS = 10
const MAX_DIMENSION = 4_096
const MAX_COORDINATE = 4_095
const generatedIdPatterns = {
  request_: /^request_[1-9][0-9]*_[0-9]+$/,
  node_: /^node_[0-9]+$/,
  edge_: /^edge_[0-9]+$/
}

const errorMessages = {
  engine_failed: "Layout engine could not compute geometry.",
  engine_unavailable: "Layout engine is unavailable.",
  invalid_engine_output: "Layout engine returned invalid geometry.",
  invalid_request: "Layout request is invalid.",
  layout_overflow: "Layout geometry exceeded v1 bounds.",
  unsupported_version: "Layout protocol version is unsupported."
}

const allowedOptions = new Map([
  ["direction", (value) => value === "RIGHT" || value === "DOWN"],
  ["edgeRouting", (value) => value === "ORTHOGONAL"],
  ["nodeNodeSpacing", positiveDimension],
  ["layerSpacing", positiveDimension],
  ["randomSeed", (value) => Number.isInteger(value) && value >= 0 && value <= 2_147_483_647],
  ["thoroughness", (value) => Number.isInteger(value) && value >= 1 && value <= 10],
  ["considerModelOrder", (value) => typeof value === "boolean"],
  ["favorStraightEdges", (value) => typeof value === "boolean"]
])

const workerPath = /^\/vendor\/layout\/worker-v1\/[a-f0-9]{64}\/aiur-layout-worker\.js$/
const enginePath = /^\/vendor\/layout\/elk-0\.11\.1\/[a-f0-9]{64}\/elk-worker\.min\.js$/

let enginePromise

self.addEventListener("message", (event) => {
  const request = event.data
  const identity = safeIdentity(request)

  Promise.resolve()
    .then(() => validateRequest(request))
    .then((validated) => layout(validated))
    .then((result) => self.postMessage(result))
    .catch((error) => self.postMessage(errorEnvelope(identity, errorCode(error))))
})

function positiveDimension(value) {
  return Number.isFinite(value) && value >= 1 && value <= MAX_DIMENSION
}

function isPlainRecord(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false

  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function hasOnlyKeys(value, allowed) {
  return Object.keys(value).every((key) => allowed.has(key))
}

function isOpaqueId(value, prefix) {
  return typeof value === "string" && value.length <= 64 && generatedIdPatterns[prefix]?.test(value) === true
}

function safeIdentity(value) {
  if (!isPlainRecord(value)) return { requestId: null, generation: null }

  return {
    requestId: isOpaqueId(value.requestId, "request_") ? value.requestId : null,
    generation: Number.isSafeInteger(value.generation) && value.generation > 0 ? value.generation : null
  }
}

function protocolError(code) {
  const error = new Error(code)
  error.code = code
  return error
}

function errorCode(error) {
  return error?.code && Object.hasOwn(errorMessages, error.code) ? error.code : "engine_failed"
}

function errorEnvelope(identity, code) {
  return {
    type: "error",
    version: PROTOCOL_VERSION,
    requestId: identity.requestId,
    generation: identity.generation,
    error: { code, message: errorMessages[code] }
  }
}

function serializedRequestSize(value) {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).byteLength
  } catch (_error) {
    return Infinity
  }
}

function validateRequest(value) {
  if (!isPlainRecord(value) || serializedRequestSize(value) > MAX_REQUEST_BYTES) throw protocolError("invalid_request")

  const allowed = new Set(["type", "version", "requestId", "generation", "nodes", "edges", "constraints", "options"])

  if (!hasOnlyKeys(value, allowed) || value.type !== "layout") throw protocolError("invalid_request")
  if (value.version !== PROTOCOL_VERSION) throw protocolError("unsupported_version")
  if (!isOpaqueId(value.requestId, "request_") || !Number.isSafeInteger(value.generation) || value.generation < 1) {
    throw protocolError("invalid_request")
  }

  if (!Array.isArray(value.nodes) || value.nodes.length > MAX_NODES || !Array.isArray(value.edges) || value.edges.length > MAX_EDGES) {
    throw protocolError("invalid_request")
  }

  const constraints = validateConstraints(value.constraints ?? {})
  const nodes = value.nodes.map((node) => validateNode(node, constraints))
  const nodeIds = new Set(nodes.map((node) => node.id))

  if (nodeIds.size !== nodes.length) throw protocolError("invalid_request")

  const edges = value.edges.map(validateEdge)
  const edgeIds = new Set(edges.map((edge) => edge.id))

  if (edgeIds.size !== edges.length || edges.some((edge) => !nodeIds.has(edge.source) || !nodeIds.has(edge.target))) {
    throw protocolError("invalid_request")
  }

  return {
    requestId: value.requestId,
    generation: value.generation,
    nodes,
    edges,
    options: validateOptions(value.options ?? {})
  }
}

function validateConstraints(value) {
  if (!isPlainRecord(value) || !hasOnlyKeys(value, new Set(["lanes", "phases"]))) throw protocolError("invalid_request")

  const lanes = validateConstraintList(value.lanes ?? [])
  const phases = validateConstraintList(value.phases ?? [])

  if (lanes.length + phases.length > MAX_CONSTRAINTS) throw protocolError("invalid_request")

  return { lanes: new Set(lanes), phases: new Set(phases) }
}

function validateConstraintList(value) {
  if (!Array.isArray(value)) throw protocolError("invalid_request")

  const indexes = value.map((entry) => {
    if (!isPlainRecord(entry) || !hasOnlyKeys(entry, new Set(["index"])) || !Number.isInteger(entry.index) || entry.index < 0 || entry.index >= MAX_CONSTRAINTS) {
      throw protocolError("invalid_request")
    }

    return entry.index
  })

  if (new Set(indexes).size !== indexes.length) throw protocolError("invalid_request")
  return indexes
}

function validateNode(value, constraints) {
  if (!isPlainRecord(value) || !hasOnlyKeys(value, new Set(["id", "width", "height", "lane", "phase", "stub"]))) {
    throw protocolError("invalid_request")
  }

  if (!isOpaqueId(value.id, "node_") || !positiveDimension(value.width) || !positiveDimension(value.height)) {
    throw protocolError("invalid_request")
  }

  const lane = value.lane ?? null
  const phase = value.phase ?? null

  if (lane !== null && (!Number.isInteger(lane) || !constraints.lanes.has(lane))) throw protocolError("invalid_request")
  if (phase !== null && (!Number.isInteger(phase) || !constraints.phases.has(phase))) throw protocolError("invalid_request")
  if (value.stub !== undefined && typeof value.stub !== "boolean") throw protocolError("invalid_request")

  return { id: value.id, width: value.width, height: value.height, lane, phase, stub: value.stub === true }
}

function validateEdge(value) {
  if (!isPlainRecord(value) || !hasOnlyKeys(value, new Set(["id", "source", "target"]))) throw protocolError("invalid_request")
  if (!isOpaqueId(value.id, "edge_") || !isOpaqueId(value.source, "node_") || !isOpaqueId(value.target, "node_")) {
    throw protocolError("invalid_request")
  }

  return { id: value.id, source: value.source, target: value.target }
}

function validateOptions(value) {
  if (!isPlainRecord(value) || Object.keys(value).length > MAX_OPTIONS) throw protocolError("invalid_request")

  for (const [key, option] of Object.entries(value)) {
    const valid = allowedOptions.get(key)
    if (!valid || !valid(option)) throw protocolError("invalid_request")
  }

  return value
}

async function layout(request) {
  const engine = await loadEngine()
  const graph = toElkGraph(request)
  const result = engine.layout(graph)

  return normalizeLayout(request, result)
}

async function loadEngine() {
  if (!enginePromise) {
    enginePromise = Promise.resolve().then(() => {
      const resolved = engineAssetUrl()

      importScripts(resolved.href)

      if (typeof self.onmessage !== "function") throw protocolError("engine_unavailable")

      const dispatch = self.onmessage
      self.onmessage = null
      return inlineEngine(dispatch)
    })
  }

  return enginePromise
}

function engineAssetUrl() {
  try {
    const worker = new URL(self.location.href)
    const parameters = Array.from(worker.searchParams.entries())

    if (!validWorkerUrl(worker) || parameters.length !== 1 || parameters[0][0] !== "engine") {
      throw protocolError("engine_unavailable")
    }

    const engine = new URL(parameters[0][1], worker.href)
    if (!validEngineUrl(engine)) throw protocolError("engine_unavailable")

    return engine
  } catch (error) {
    if (error?.code === "engine_unavailable") throw error
    throw protocolError("engine_unavailable")
  }
}

function validWorkerUrl(url) {
  return url.origin === self.location.origin &&
    url.username === "" &&
    url.password === "" &&
    url.hash === "" &&
    workerPath.test(url.pathname)
}

function validEngineUrl(url) {
  return url.origin === self.location.origin &&
    url.username === "" &&
    url.password === "" &&
    url.search === "" &&
    url.hash === "" &&
    enginePath.test(url.pathname)
}

function inlineEngine(dispatch) {
  let registered = false
  let nextId = 1

  function invoke(message) {
    let response
    const postMessage = self.postMessage

    self.postMessage = (value) => {
      response = value
    }

    try {
      dispatch({ data: { ...message, id: nextId++ } })
    } finally {
      self.postMessage = postMessage
    }

    if (!isPlainRecord(response)) throw protocolError("engine_failed")
    if (response.error) throw protocolError("engine_failed")
    return response.data
  }

  return {
    layout(graph) {
      if (!registered) {
        invoke({ cmd: "register", algorithms: ["layered"] })
        registered = true
      }

      return invoke({ cmd: "layout", graph, layoutOptions: {}, options: {} })
    }
  }
}

function toElkGraph(request) {
  const options = request.options

  return {
    id: "aiur_geometry",
    layoutOptions: {
      "elk.algorithm": "layered",
      "elk.direction": options.direction ?? "RIGHT",
      "elk.edgeRouting": options.edgeRouting ?? "ORTHOGONAL",
      "elk.spacing.nodeNode": String(options.nodeNodeSpacing ?? 30),
      "elk.layered.spacing.nodeNodeBetweenLayers": String(options.layerSpacing ?? 50),
      "elk.randomSeed": String(options.randomSeed ?? 1),
      "elk.layered.thoroughness": String(options.thoroughness ?? 7),
      "elk.layered.considerModelOrder.strategy": modelOrderStrategy(options),
      "elk.layered.considerModelOrder.components": "FORCE_MODEL_ORDER",
      "elk.layered.considerModelOrder.groupModelOrder.cmGroupOrderStrategy": "ENFORCED",
      "elk.layered.nodePlacement.favorStraightEdges": String(options.favorStraightEdges ?? true),
      "elk.partitioning.activate": "true",
      "elk.separateConnectedComponents": "false"
    },
    children: request.nodes.map((node) => ({
      id: node.id,
      width: node.width,
      height: node.height,
      layoutOptions: partitionOptions(node)
    })),
    edges: request.edges.map((edge) => ({ id: edge.id, sources: [edge.source], targets: [edge.target] }))
  }
}

function modelOrderStrategy(options) {
  return options.considerModelOrder === false ? "NONE" : "NODES_AND_EDGES"
}

function partitionOptions(node) {
  if (node.lane === null && node.phase === null) return {}

  return {
    "elk.partitioning.partition": String(node.phase ?? 0),
    "elk.layered.considerModelOrder.groupModelOrder.crossingMinimizationId": String(node.lane ?? 0),
    "elk.layered.considerModelOrder.groupModelOrder.componentGroupId": String(node.lane ?? 0)
  }
}

function normalizeLayout(request, result) {
  if (!isPlainRecord(result) || !Array.isArray(result.children) || !Array.isArray(result.edges)) throw protocolError("invalid_engine_output")

  const resultNodes = new Map(result.children.map((node) => [node.id, node]))
  const resultEdges = new Map(result.edges.map((edge) => [edge.id, edge]))
  const nodes = request.nodes.map((node) => normalizeNode(node, resultNodes.get(node.id)))
  const edges = request.edges.map((edge) => normalizeEdge(edge, resultEdges.get(edge.id)))
  const externalStubs = request.nodes.filter((node) => node.stub).length
  const diagnostics = externalStubs === 0 ? [] : [{ code: "external_stubs", count: externalStubs }]

  if (diagnostics.length > MAX_DIAGNOSTICS) throw protocolError("invalid_engine_output")

  return {
    type: "result",
    version: PROTOCOL_VERSION,
    requestId: request.requestId,
    generation: request.generation,
    nodes,
    edges,
    diagnostics
  }
}

function normalizeNode(node, result) {
  if (!isPlainRecord(result)) throw protocolError("invalid_engine_output")

  return {
    id: node.id,
    x: boundedCoordinate(result.x),
    y: boundedCoordinate(result.y),
    width: node.width,
    height: node.height
  }
}

function normalizeEdge(edge, result) {
  if (!isPlainRecord(result)) throw protocolError("invalid_engine_output")

  const sections = result.sections ?? []
  if (!Array.isArray(sections) || sections.length > MAX_SECTIONS) throw protocolError("invalid_engine_output")

  return { id: edge.id, sections: sections.map(normalizeSection) }
}

function normalizeSection(section) {
  if (!isPlainRecord(section) || !isPlainRecord(section.startPoint) || !isPlainRecord(section.endPoint)) {
    throw protocolError("invalid_engine_output")
  }

  const bendPoints = section.bendPoints ?? []
  if (!Array.isArray(bendPoints) || bendPoints.length > MAX_POINTS) throw protocolError("invalid_engine_output")

  return {
    startPoint: normalizePoint(section.startPoint),
    bendPoints: bendPoints.map(normalizePoint),
    endPoint: normalizePoint(section.endPoint)
  }
}

function normalizePoint(point) {
  return { x: boundedCoordinate(point.x), y: boundedCoordinate(point.y) }
}

function boundedCoordinate(value) {
  if (!Number.isFinite(value) || value < 0 || value > MAX_COORDINATE) throw protocolError("layout_overflow")

  return Math.round(value * 1_000) / 1_000 + 1
}

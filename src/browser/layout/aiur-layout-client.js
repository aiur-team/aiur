export const LAYOUT_PROTOCOL_VERSION = 1

const REQUEST_TIMEOUT_MS = 5_000
const MAX_REQUEST_BYTES = 256 * 1024
const MAX_NODES = 100
const MAX_EDGES = 1_000
const MAX_CONSTRAINTS = 100
const MAX_OPTIONS = 8
const MAX_SECTIONS = 16
const MAX_POINTS = 64
const MAX_DIAGNOSTICS = 10
const MAX_DIMENSION = 4_096
const generatedIdPatterns = {
  request_: /^request_[1-9][0-9]*_[0-9]+$/,
  node_: /^node_[0-9]+$/,
  edge_: /^edge_[0-9]+$/
}
const errorMessages = {
  asset_url_invalid: "Layout assets are unavailable.",
  invalid_request: "Layout request is invalid.",
  malformed_response: "Layout worker returned an invalid response.",
  request_timeout: "Layout worker timed out.",
  worker_failed: "Layout worker failed.",
  worker_start_failed: "Layout worker could not start.",
  worker_unsupported: "Layout worker is unsupported."
}
const workerErrorMessages = {
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

export function createLayoutWorkerClient(options = {}) {
  const { workerUrl, engineUrl, timeoutMs = REQUEST_TIMEOUT_MS } = options
  const WorkerConstructor = Object.hasOwn(options, "WorkerConstructor") ? options.WorkerConstructor : globalThis.Worker
  let worker = null
  const pending = new Map()

  function layout(value) {
    const identity = safeIdentity(value)
    const request = normalizeRequest(value)
    const key = requestKey(identity)

    if (!request || pending.has(key)) return Promise.resolve(errorEnvelope(identity, "invalid_request"))
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > REQUEST_TIMEOUT_MS) return Promise.resolve(errorEnvelope(identity, "invalid_request"))
    if (typeof WorkerConstructor !== "function") return Promise.resolve(errorEnvelope(identity, "worker_unsupported"))
    if (!validAssetUrls(workerUrl, engineUrl)) return Promise.resolve(errorEnvelope(identity, "asset_url_invalid"))

    const activeWorker = ensureWorker()
    if (!activeWorker) return Promise.resolve(errorEnvelope(identity, "worker_start_failed"))

    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (!pending.has(key)) return
        pending.delete(key)
        resolve(errorEnvelope(identity, "request_timeout"))
        restart("worker_failed")
      }, timeoutMs)

      pending.set(key, { identity, request, resolve, timer })

      try {
        activeWorker.postMessage(request)
      } catch (_error) {
        settle(key, errorEnvelope(identity, "worker_failed"))
        restart("worker_failed")
      }
    })
  }

  function dispose() {
    rejectPending("worker_failed")
    worker?.terminate()
    worker = null
  }

  function ensureWorker() {
    if (worker) return worker

    try {
      const workerWithEngine = `${workerUrl}?engine=${encodeURIComponent(engineUrl)}`
      const activeWorker = new WorkerConstructor(workerWithEngine)
      worker = activeWorker
      activeWorker.addEventListener("message", (event) => {
        if (worker === activeWorker) handleMessage(event)
      })
      activeWorker.addEventListener("error", () => {
        if (worker === activeWorker) restart("worker_failed")
      })
      activeWorker.addEventListener("messageerror", () => {
        if (worker === activeWorker) restart("worker_failed")
      })
      return activeWorker
    } catch (_error) {
      worker = null
      return null
    }
  }

  function handleMessage(event) {
    const response = event.data
    const identity = safeIdentity(response)
    const key = requestKey(identity)
    const entry = pending.get(key)

    if (!entry) {
      if (!validIdentity(identity)) restart("malformed_response")
      return
    }
    if (!validResponse(response, entry)) {
      settle(key, errorEnvelope(identity, "malformed_response"))
      return
    }

    settle(key, response)
  }

  function settle(key, response) {
    const entry = pending.get(key)
    if (!entry) return

    pending.delete(key)
    clearTimeout(entry.timer)
    entry.resolve(response)
  }

  function restart(code) {
    worker?.terminate()
    worker = null
    rejectPending(code)
  }

  function rejectPending(code) {
    for (const [key, entry] of pending) {
      pending.delete(key)
      clearTimeout(entry.timer)
      entry.resolve(errorEnvelope(entry.identity, code))
    }
  }

  return { dispose, layout }
}

function validAssetUrls(workerUrl, engineUrl) {
  if (typeof globalThis.location?.href !== "string") return false

  try {
    const worker = new URL(workerUrl, globalThis.location.href)
    const engine = new URL(engineUrl, globalThis.location.href)

    return worker.origin === globalThis.location.origin &&
      engine.origin === globalThis.location.origin &&
      workerPath.test(worker.pathname) &&
      enginePath.test(engine.pathname)
  } catch (_error) {
    return false
  }
}

function safeIdentity(value) {
  if (!isRecord(value)) return { requestId: null, generation: null }

  return {
    requestId: validId(value.requestId, "request_") ? value.requestId : null,
    generation: Number.isSafeInteger(value.generation) && value.generation > 0 ? value.generation : null
  }
}

function validIdentity(identity) {
  return identity.requestId !== null && identity.generation !== null
}

function normalizeRequest(value) {
  if (!isRecord(value) || serializedRequestSize(value) > MAX_REQUEST_BYTES) return null

  const allowed = new Set(["type", "version", "requestId", "generation", "nodes", "edges", "constraints", "options"])
  if (!hasOnlyKeys(value, allowed) || value.type !== "layout" || value.version !== LAYOUT_PROTOCOL_VERSION) return null
  if (!validId(value.requestId, "request_") || !Number.isSafeInteger(value.generation) || value.generation < 1) return null
  if (!Array.isArray(value.nodes) || value.nodes.length > MAX_NODES || !Array.isArray(value.edges) || value.edges.length > MAX_EDGES) return null

  const constraints = normalizeConstraints(value.constraints ?? {})
  if (!constraints) return null

  const nodes = value.nodes.map((node) => normalizeNode(node, constraints))
  if (nodes.some((node) => node === null) || new Set(nodes.map((node) => node.id)).size !== nodes.length) return null

  const edges = value.edges.map(normalizeEdge)
  if (edges.some((edge) => edge === null) || new Set(edges.map((edge) => edge.id)).size !== edges.length) return null
  if (edges.some((edge) => !nodes.some((node) => node.id === edge.source) || !nodes.some((node) => node.id === edge.target))) return null

  const options = normalizeOptions(value.options ?? {})
  if (!options) return null

  return {
    type: "layout",
    version: LAYOUT_PROTOCOL_VERSION,
    requestId: value.requestId,
    generation: value.generation,
    nodes,
    edges,
    constraints: { lanes: constraints.lanes, phases: constraints.phases },
    options
  }
}

function normalizeConstraints(value) {
  if (!isRecord(value) || !hasOnlyKeys(value, new Set(["lanes", "phases"]))) return null

  const lanes = normalizeConstraintList(value.lanes ?? [])
  const phases = normalizeConstraintList(value.phases ?? [])
  if (!lanes || !phases || lanes.length + phases.length > MAX_CONSTRAINTS) return null

  return { lanes, phases, laneIndexes: new Set(lanes.map(({ index }) => index)), phaseIndexes: new Set(phases.map(({ index }) => index)) }
}

function normalizeConstraintList(value) {
  if (!Array.isArray(value)) return null

  const entries = value.map((entry) => {
    if (!isRecord(entry) || !hasOnlyKeys(entry, new Set(["index"])) || !Number.isInteger(entry.index) || entry.index < 0 || entry.index >= MAX_CONSTRAINTS) return null
    return { index: entry.index }
  })

  return entries.some((entry) => entry === null) || new Set(entries.map(({ index }) => index)).size !== entries.length ? null : entries
}

function normalizeNode(value, constraints) {
  if (!isRecord(value) || !hasOnlyKeys(value, new Set(["id", "width", "height", "lane", "phase", "stub"]))) return null
  if (!validId(value.id, "node_") || !positiveDimension(value.width) || !positiveDimension(value.height)) return null

  const lane = value.lane ?? null
  const phase = value.phase ?? null
  if (lane !== null && (!Number.isInteger(lane) || !constraints.laneIndexes.has(lane))) return null
  if (phase !== null && (!Number.isInteger(phase) || !constraints.phaseIndexes.has(phase))) return null
  if (value.stub !== undefined && typeof value.stub !== "boolean") return null

  return { id: value.id, width: value.width, height: value.height, lane, phase, stub: value.stub === true }
}

function normalizeEdge(value) {
  if (!isRecord(value) || !hasOnlyKeys(value, new Set(["id", "source", "target"]))) return null
  if (!validId(value.id, "edge_") || !validId(value.source, "node_") || !validId(value.target, "node_")) return null
  return { id: value.id, source: value.source, target: value.target }
}

function normalizeOptions(value) {
  if (!isRecord(value) || Object.keys(value).length > MAX_OPTIONS) return null

  const options = {}
  for (const [key, option] of Object.entries(value)) {
    const valid = allowedOptions.get(key)
    if (!valid || !valid(option)) return null
    options[key] = option
  }

  return options
}

function validResponse(value, entry) {
  if (!isRecord(value) || value.version !== LAYOUT_PROTOCOL_VERSION || value.requestId !== entry.identity.requestId || value.generation !== entry.identity.generation) return false

  if (value.type === "result") return validResult(value, entry.request)

  return hasOnlyKeys(value, new Set(["type", "version", "requestId", "generation", "error"])) &&
    value.type === "error" && isRecord(value.error) && hasOnlyKeys(value.error, new Set(["code", "message"])) &&
    Object.hasOwn(workerErrorMessages, value.error.code) && value.error.message === workerErrorMessages[value.error.code]
}

function validResult(value, request) {
  if (!hasOnlyKeys(value, new Set(["type", "version", "requestId", "generation", "nodes", "edges", "diagnostics"]))) return false
  if (!Array.isArray(value.nodes) || value.nodes.length > MAX_NODES || !Array.isArray(value.edges) || value.edges.length > MAX_EDGES || !Array.isArray(value.diagnostics) || value.diagnostics.length > MAX_DIAGNOSTICS) return false
  if (!value.nodes.every(validResultNode) || !value.edges.every(validResultEdge) || !value.diagnostics.every(validDiagnostic)) return false

  return sameIds(value.nodes, request.nodes) && sameIds(value.edges, request.edges)
}

function validResultNode(value) {
  return isRecord(value) && hasOnlyKeys(value, new Set(["id", "x", "y", "width", "height"])) &&
    validId(value.id, "node_") && positiveCoordinate(value.x) && positiveCoordinate(value.y) &&
    positiveDimension(value.width) && positiveDimension(value.height)
}

function validResultEdge(value) {
  return isRecord(value) && hasOnlyKeys(value, new Set(["id", "sections"])) && validId(value.id, "edge_") &&
    Array.isArray(value.sections) && value.sections.length <= MAX_SECTIONS && value.sections.every(validSection)
}

function validSection(value) {
  return isRecord(value) && hasOnlyKeys(value, new Set(["startPoint", "bendPoints", "endPoint"])) &&
    validPoint(value.startPoint) && Array.isArray(value.bendPoints) && value.bendPoints.length <= MAX_POINTS &&
    value.bendPoints.every(validPoint) && validPoint(value.endPoint)
}

function validPoint(value) {
  return isRecord(value) && hasOnlyKeys(value, new Set(["x", "y"])) && positiveCoordinate(value.x) && positiveCoordinate(value.y)
}

function validDiagnostic(value) {
  return isRecord(value) && hasOnlyKeys(value, new Set(["code", "count"])) && value.code === "external_stubs" &&
    Number.isInteger(value.count) && value.count >= 1 && value.count <= MAX_NODES
}

function sameIds(result, request) {
  const resultIds = new Set(result.map(({ id }) => id))
  return resultIds.size === result.length && resultIds.size === request.length && request.every(({ id }) => resultIds.has(id))
}

function serializedRequestSize(value) {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).byteLength
  } catch (_error) {
    return Infinity
  }
}

function positiveDimension(value) {
  return Number.isFinite(value) && value >= 1 && value <= MAX_DIMENSION
}

function positiveCoordinate(value) {
  return Number.isFinite(value) && value >= 1 && value <= MAX_DIMENSION
}

function hasOnlyKeys(value, allowed) {
  return Object.keys(value).every((key) => allowed.has(key))
}

function errorEnvelope(identity, code) {
  return {
    type: "error",
    version: LAYOUT_PROTOCOL_VERSION,
    requestId: identity.requestId,
    generation: identity.generation,
    error: { code, message: errorMessages[code] }
  }
}

function requestKey(identity) {
  return `${identity.requestId ?? ""}\u0000${identity.generation ?? ""}`
}

function validId(value, prefix) {
  return typeof value === "string" && value.length <= 64 && generatedIdPatterns[prefix]?.test(value) === true
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

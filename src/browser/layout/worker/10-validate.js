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

function requestGeneration(requestId) {
  const match = typeof requestId === "string" ? /^request_([1-9][0-9]*)_[0-9]+$/.exec(requestId) : null
  const generation = match ? Number(match[1]) : null
  return Number.isSafeInteger(generation) ? generation : null
}

function validRequestIdentity(requestId, generation) {
  return isOpaqueId(requestId, "request_") &&
    Number.isSafeInteger(generation) &&
    generation > 0 &&
    requestGeneration(requestId) === generation
}

function denseArray(value, maximumLength) {
  if (!Array.isArray(value) || value.length > maximumLength) return false

  for (let index = 0; index < value.length; index += 1) {
    if (!Object.hasOwn(value, index)) return false
  }

  return Reflect.ownKeys(value).filter((key) => Object.prototype.propertyIsEnumerable.call(value, key)).length === value.length
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

function serializedPayloadSize(value) {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).byteLength
  } catch (_error) {
    return Infinity
  }
}

function validateRequest(value) {
  if (!isPlainRecord(value)) throw protocolError("invalid_request")

  const allowed = new Set(["type", "version", "requestId", "generation", "nodes", "edges", "constraints", "options"])

  if (!hasOnlyKeys(value, allowed) || value.type !== "layout") throw protocolError("invalid_request")
  if (value.version !== PROTOCOL_VERSION) throw protocolError("unsupported_version")
  if (!validRequestIdentity(value.requestId, value.generation)) {
    throw protocolError("invalid_request")
  }

  if (!denseArray(value.nodes, MAX_NODES) || !denseArray(value.edges, MAX_EDGES)) {
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

  const request = {
    type: "layout",
    version: PROTOCOL_VERSION,
    requestId: value.requestId,
    generation: value.generation,
    nodes,
    edges,
    constraints: { lanes: constraints.lanes, phases: constraints.phases },
    options: validateOptions(value.options ?? {})
  }

  if (serializedPayloadSize(request) > MAX_REQUEST_BYTES) throw protocolError("invalid_request")
  return request
}

function validateConstraints(value) {
  if (!isPlainRecord(value) || !hasOnlyKeys(value, new Set(["lanes", "phases"]))) throw protocolError("invalid_request")

  const lanes = validateConstraintList(value.lanes ?? [])
  const phases = validateConstraintList(value.phases ?? [])

  if (lanes.length + phases.length > MAX_CONSTRAINTS) throw protocolError("invalid_request")

  return { lanes, phases, laneIndexes: new Set(lanes), phaseIndexes: new Set(phases) }
}

function validateConstraintList(value) {
  if (!denseArray(value, MAX_CONSTRAINTS)) throw protocolError("invalid_request")

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

  if (lane !== null && (!Number.isInteger(lane) || !constraints.laneIndexes.has(lane))) throw protocolError("invalid_request")
  if (phase !== null && (!Number.isInteger(phase) || !constraints.phaseIndexes.has(phase))) throw protocolError("invalid_request")
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


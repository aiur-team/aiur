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
      "elk.layered.considerModelOrder.components": "GROUP_MODEL_ORDER",
      "elk.layered.considerModelOrder.groupModelOrder.cmGroupOrderStrategy": "ENFORCED",
      "elk.layered.nodePlacement.favorStraightEdges": String(options.favorStraightEdges ?? true),
      "elk.partitioning.activate": "true",
      "elk.separateConnectedComponents": "false"
    },
    children: orderedNodes(request.nodes).map((node) => ({
      id: node.id,
      width: node.width,
      height: node.height,
      layoutOptions: partitionOptions(node)
    })),
    edges: orderedEdges(request.edges).map((edge) => ({ id: edge.id, sources: [edge.source], targets: [edge.target] }))
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

function orderedNodes(nodes) {
  return [...nodes].sort((left, right) =>
    constraintOrder(left.phase) - constraintOrder(right.phase) ||
      constraintOrder(left.lane) - constraintOrder(right.lane) ||
      compareGeneratedIds(left.id, right.id)
  )
}

function constraintOrder(value) {
  return value ?? -1
}

function compareGeneratedIds(left, right) {
  const leftSuffix = left.slice(left.lastIndexOf("_") + 1).replace(/^0+(?=\d)/, "")
  const rightSuffix = right.slice(right.lastIndexOf("_") + 1).replace(/^0+(?=\d)/, "")

  return leftSuffix.length - rightSuffix.length || leftSuffix.localeCompare(rightSuffix) || left.localeCompare(right)
}

function orderedEdges(edges) {
  return [...edges].sort((left, right) => compareGeneratedIds(left.id, right.id))
}

function normalizeLayout(request, result) {
  if (!isPlainRecord(result) || !denseArray(result.children, MAX_NODES) || !denseArray(result.edges, MAX_EDGES)) throw protocolError("invalid_engine_output")

  validateResultIdentities(result.children, request.nodes)
  validateResultIdentities(result.edges, request.edges)

  const resultNodes = new Map(result.children.map((node) => [node.id, node]))
  const resultEdges = new Map(result.edges.map((edge) => [edge.id, edge]))
  const nodes = request.nodes.map((node) => normalizeNode(node, resultNodes.get(node.id)))
  const geometry = { routePoints: 0 }
  const edges = request.edges.map((edge) => normalizeEdge(edge, resultEdges.get(edge.id), geometry))
  const externalStubs = request.nodes.filter((node) => node.stub).length
  const diagnostics = externalStubs === 0 ? [] : [{ code: "external_stubs", count: externalStubs }]

  if (diagnostics.length > MAX_DIAGNOSTICS) throw protocolError("invalid_engine_output")

  const response = {
    type: "result",
    version: PROTOCOL_VERSION,
    requestId: request.requestId,
    generation: request.generation,
    nodes,
    edges,
    diagnostics
  }

  if (serializedPayloadSize(response) > MAX_RESPONSE_BYTES) throw protocolError("layout_overflow")

  return response
}

function validateResultIdentities(resultEntries, requestEntries) {
  if (resultEntries.length !== requestEntries.length) throw protocolError("invalid_engine_output")

  const expectedIds = new Set(requestEntries.map(({ id }) => id))
  const resultIds = new Set()

  for (const entry of resultEntries) {
    if (!isPlainRecord(entry) || !expectedIds.has(entry.id) || resultIds.has(entry.id)) {
      throw protocolError("invalid_engine_output")
    }

    resultIds.add(entry.id)
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

function normalizeEdge(edge, result, geometry) {
  if (!isPlainRecord(result)) throw protocolError("invalid_engine_output")

  const sections = result.sections ?? []
  if (!denseArray(sections, MAX_SECTIONS)) throw protocolError("invalid_engine_output")

  return { id: edge.id, sections: sections.map((section) => normalizeSection(section, geometry)) }
}

function normalizeSection(section, geometry) {
  if (!isPlainRecord(section) || !isPlainRecord(section.startPoint) || !isPlainRecord(section.endPoint)) {
    throw protocolError("invalid_engine_output")
  }

  const bendPoints = section.bendPoints ?? []
  if (!denseArray(bendPoints, MAX_BEND_POINTS)) throw protocolError("invalid_engine_output")

  const pointCount = bendPoints.length + 2
  if (geometry.routePoints + pointCount > MAX_ROUTE_POINTS) throw protocolError("layout_overflow")
  geometry.routePoints += pointCount

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

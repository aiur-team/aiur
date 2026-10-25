const PROTOCOL_VERSION = 1
const MAX_REQUEST_BYTES = 256 * 1024
const MAX_RESPONSE_BYTES = 256 * 1024
const MAX_NODES = 100
const MAX_EDGES = 1_000
const MAX_CONSTRAINTS = 100
const MAX_OPTIONS = 8
const MAX_SECTIONS = 16
const MAX_SECTION_POINTS = 64
const MAX_BEND_POINTS = MAX_SECTION_POINTS - 2
const MAX_ROUTE_POINTS = 8_000
const MAX_DIAGNOSTICS = 10
const MAX_DIMENSION = 4_096
const MAX_COORDINATE = 65_535
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


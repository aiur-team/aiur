import { EDGE_STATES, geometryBounds, healthMessages, now, safeCode } from "./protocol.js"

export function applyLayout(element, response, measured, instance) {
  const cards = element.querySelector("[data-layout-cards]")
  const svg = element.querySelector("[data-layout-edges]")
  if (!cards || !svg) return false

  const geometry = geometryBounds(response)
  if (!geometry) return false

  for (const node of response.nodes) {
    const card = measured.cardsByWorkerId.get(node.id)
    if (!card) return false

    card.style.setProperty("--bo-layout-x", `${node.x}px`)
    card.style.setProperty("--bo-layout-y", `${node.y}px`)
    card.style.setProperty("--bo-layout-width", `${node.width}px`)
    card.style.setProperty("--bo-layout-height", `${node.height}px`)
  }

  cards.style.minWidth = `${geometry.width}px`
  cards.style.minHeight = `${geometry.height}px`
  drawEdges(svg, response.edges, measured.edgeRecords, geometry, instance)

  element.classList.remove("is-layout-fallback")
  element.classList.add("is-layout-ready")
  element.dataset.layoutDiscardedResponse = ""
  setLayoutHealth(element, "ready", now() - measured.startedAt)
  return true
}

export function applyFallback(element, reason) {
  clearVisualLayout(element)
  element.classList.remove("is-layout-ready")
  element.classList.add("is-layout-fallback")
  setLayoutHealth(element, "fallback", undefined, reason)
}

export function clearVisualLayout(element) {
  element.querySelectorAll("[data-layout-node]").forEach((card) => {
    card.style.removeProperty("--bo-layout-x")
    card.style.removeProperty("--bo-layout-y")
    card.style.removeProperty("--bo-layout-width")
    card.style.removeProperty("--bo-layout-height")
  })

  const cards = element.querySelector("[data-layout-cards]")
  cards?.style.removeProperty("min-width")
  cards?.style.removeProperty("min-height")

  const svg = element.querySelector("[data-layout-edges]")
  svg?.replaceChildren()
  svg?.removeAttribute("viewBox")
  svg?.removeAttribute("width")
  svg?.removeAttribute("height")
}

export function setLayoutHealth(element, health, durationMs, reason) {
  const message = element.querySelector("[data-layout-health-message]")
  element.dataset.layoutHealth = health
  if (reason) element.dataset.layoutFailure = safeCode(reason)
  else delete element.dataset.layoutFailure
  if (message) message.textContent = healthMessages[health] || healthMessages.fallback

  element.dispatchEvent(new CustomEvent("aiur:layout-health", {
    bubbles: true,
    detail: {
      health,
      durationMs: Number.isFinite(durationMs) ? Math.round(durationMs) : null,
      reason: reason ? safeCode(reason) : null
    }
  }))
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
    return smoothPath(points)
  }).join(" ")
}

// Render the ELK route as a smooth curve instead of an orthogonal polyline.
// A Catmull-Rom spline through the route points is converted to cubic Béziers,
// so edges follow the same routing (never cutting through cards) while reading
// as the flowing dependency curves from the Build Order design.
function smoothPath(points) {
  if (points.length < 2) return ""
  if (points.length === 2) {
    // Straight source→target: bow it into a gentle S-curve so single dependency
    // hops still read as curves (matches the design's edge style). The control
    // points carry a horizontal lean so a column-crossing hop reads as a clean
    // diagonal rather than a vertical zig-zag; dy is signed so the bow follows
    // the layout direction rather than assuming source-above-target.
    const [a, b] = points
    const span = b.y - a.y
    const dy = Math.sign(span || 1) * Math.max(18, Math.abs(span) * 0.45)
    const lean = (b.x - a.x) * 0.2
    return `M${a.x} ${a.y} C${a.x + lean} ${a.y + dy}, ${b.x - lean} ${b.y - dy}, ${b.x} ${b.y}`
  }

  let path = `M${points[0].x} ${points[0].y}`
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[i === 0 ? 0 : i - 1]
    const p1 = points[i]
    const p2 = points[i + 1]
    const p3 = points[i + 2 < points.length ? i + 2 : points.length - 1]
    const c1x = p1.x + (p2.x - p0.x) / 6
    const c1y = p1.y + (p2.y - p0.y) / 6
    const c2x = p2.x - (p3.x - p1.x) / 6
    const c2y = p2.y - (p3.y - p1.y) / 6
    path += ` C${c1x} ${c1y}, ${c2x} ${c2y}, ${p2.x} ${p2.y}`
  }
  return path
}

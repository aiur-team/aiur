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
  element.querySelector("[data-layout-edges]")?.replaceChildren()
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
    return points.map((point, index) => `${index === 0 ? "M" : "L"}${point.x} ${point.y}`).join(" ")
  }).join(" ")
}

import { clampPan, clampZoom, fitZoom, MAX_ZOOM, MIN_ZOOM, PAN_STEP, stepZoom, zoomPercent } from "./interaction-policy.js"

// One interaction-state owner per selected root. The DOM/SVG layout adapter owns
// this instance and drives its mount/refresh/reset/destroy from the LiveView hook
// lifecycle, so pan/zoom/selection stay scoped to the current root generation and
// reset deterministically when the root changes.
//
// This controller applies visual transforms and reports state. It never invents
// adjacency: the upstream/downstream closure is precomputed server-side and read
// from each card's data attributes.
export class GraphInteraction {
  constructor(root, options = {}) {
    this.root = root
    this.options = options
    this.win = options.window || window
    this.doc = options.document || (root.ownerDocument || document)
    this.destroyed = false
    this.scale = 1
    this.pan = { x: 0, y: 0 }
    this.selected = null
    this.hovered = null
    this.focused = null
    this.dragging = null
    this.announceTimer = null
    this.pendingAnnouncement = null

    this.onZoomClick = this.handleZoomClick.bind(this)
    this.onWheel = this.handleWheel.bind(this)
    this.onPointerDown = this.handlePointerDown.bind(this)
    this.onPointerMove = this.handlePointerMove.bind(this)
    this.onPointerUp = this.handlePointerUp.bind(this)
    this.onCardsFocusIn = this.handleFocusIn.bind(this)
    this.onCardsFocusOut = this.handleFocusOut.bind(this)
    this.onCardsPointerOver = this.handlePointerOver.bind(this)
    this.onCardsPointerOut = this.handlePointerOut.bind(this)
    this.onCardsClick = this.handleCardClick.bind(this)
    this.onKeydown = this.handleKeydown.bind(this)
  }

  mount() {
    this.captureElements()
    if (!this.viewport) return

    this.controls.forEach((button) => button.addEventListener("click", this.onZoomClick))
    this.viewport.addEventListener("wheel", this.onWheel, { passive: false })
    this.viewport.addEventListener("pointerdown", this.onPointerDown)
    this.win.addEventListener("pointermove", this.onPointerMove)
    this.win.addEventListener("pointerup", this.onPointerUp)
    this.viewport.addEventListener("focusin", this.onCardsFocusIn)
    this.viewport.addEventListener("focusout", this.onCardsFocusOut)
    this.viewport.addEventListener("pointerover", this.onCardsPointerOver)
    this.viewport.addEventListener("pointerout", this.onCardsPointerOut)
    this.viewport.addEventListener("click", this.onCardsClick)
    this.viewport.addEventListener("keydown", this.onKeydown)

    this.applyTransform()
    this.applyHighlight()
  }

  // LiveView patched the graph in place (same root/generation). Reconcile the
  // selection against the surviving cards; a removed selection clears safely.
  refresh() {
    if (this.destroyed) return
    this.captureElements()
    if (this.selected && !this.cardById(this.selected)) this.selected = null
    // Re-sync transient focus from the live DOM: LiveView preserves focus across
    // a patch, so re-read it rather than dropping the focus highlight each tick.
    this.focused = this.doc.activeElement?.closest?.("[data-graph-node]")?.dataset.graphNode || null
    this.hovered = null
    this.applyTransform()
    this.applyHighlight()
  }

  // The root or data generation changed. Interaction state is disposable and
  // scoped to a generation, so drop it entirely.
  reset() {
    if (this.destroyed) return
    this.scale = 1
    this.pan = { x: 0, y: 0 }
    this.selected = null
    this.focused = null
    this.hovered = null
    this.dragging = null
    this.captureElements()
    this.applyTransform()
    this.applyHighlight()
  }

  destroy() {
    if (this.destroyed) return
    this.destroyed = true
    if (this.announceTimer) this.win.clearTimeout(this.announceTimer)
    this.controls.forEach((button) => button.removeEventListener("click", this.onZoomClick))
    this.viewport?.removeEventListener("wheel", this.onWheel)
    this.viewport?.removeEventListener("pointerdown", this.onPointerDown)
    this.win.removeEventListener("pointermove", this.onPointerMove)
    this.win.removeEventListener("pointerup", this.onPointerUp)
    this.viewport?.removeEventListener("focusin", this.onCardsFocusIn)
    this.viewport?.removeEventListener("focusout", this.onCardsFocusOut)
    this.viewport?.removeEventListener("pointerover", this.onCardsPointerOver)
    this.viewport?.removeEventListener("pointerout", this.onCardsPointerOut)
    this.viewport?.removeEventListener("click", this.onCardsClick)
    this.viewport?.removeEventListener("keydown", this.onKeydown)
  }

  captureElements() {
    this.viewport = this.root.querySelector("[data-graph-viewport]")
    this.content = this.root.querySelector("[data-graph-content]")
    this.readout = this.root.querySelector("[data-graph-zoom-level]")
    this.announceRegion = this.root.querySelector("[data-graph-announce]")
    this.controls = Array.from(this.root.querySelectorAll("[data-graph-zoom]"))
    this.cards = Array.from(this.root.querySelectorAll("[data-graph-node]"))
  }

  ready() {
    return this.root.classList.contains("is-layout-ready")
  }

  // --- zoom / pan ---------------------------------------------------------

  handleZoomClick(event) {
    const action = event.currentTarget.dataset.graphZoom
    if (action === "in") this.setZoom(stepZoom(this.scale, 1), "buttons")
    else if (action === "out") this.setZoom(stepZoom(this.scale, -1), "buttons")
    else if (action === "fit") this.fit()
    else if (action === "reset") this.resetView()
  }

  handleWheel(event) {
    // Only intentional graph zoom captures the wheel; ordinary scrolling stays
    // with the page (see ticket non-goals).
    if (!this.ready() || !(event.ctrlKey || event.metaKey)) return
    event.preventDefault()
    const direction = event.deltaY < 0 ? 1 : -1
    this.setZoom(stepZoom(this.scale, direction), "wheel")
  }

  handlePointerDown(event) {
    if (!this.ready() || event.button !== 0) return
    // Pan only from the canvas background, never when starting on a card/control.
    if (event.target.closest("[data-graph-node]") || event.target.closest("[data-graph-zoom]")) return
    this.dragging = { pointerId: event.pointerId, startX: event.clientX, startY: event.clientY, origin: { ...this.pan } }
    this.viewport.classList.add("is-graph-panning")
  }

  handlePointerMove(event) {
    if (!this.dragging || event.pointerId !== this.dragging.pointerId) return
    const next = {
      x: this.dragging.origin.x + (event.clientX - this.dragging.startX),
      y: this.dragging.origin.y + (event.clientY - this.dragging.startY)
    }
    this.pan = clampPan(next, this.contentSize(), this.viewportSize(), this.scale)
    this.applyTransform()
  }

  handlePointerUp(event) {
    if (!this.dragging || event.pointerId !== this.dragging.pointerId) return
    this.dragging = null
    this.viewport.classList.remove("is-graph-panning")
  }

  panBy(dx, dy) {
    if (!this.ready()) return
    const next = { x: this.pan.x + dx, y: this.pan.y + dy }
    this.pan = clampPan(next, this.contentSize(), this.viewportSize(), this.scale)
    this.applyTransform()
  }

  setZoom(scale, source) {
    const next = clampZoom(scale)
    const changed = next !== this.scale
    this.scale = next
    this.pan = clampPan(this.pan, this.contentSize(), this.viewportSize(), this.scale)
    this.applyTransform()
    if (changed || source === "wheel") this.announce(`Zoom ${zoomPercent(this.scale)} percent`)
  }

  fit() {
    this.pan = { x: 0, y: 0 }
    this.setZoom(fitZoom(this.contentSize(), this.viewportSize()), "fit")
  }

  resetView() {
    this.pan = { x: 0, y: 0 }
    this.setZoom(1, "reset")
    this.announce("View reset to 100 percent")
  }

  applyTransform() {
    if (!this.content) return
    this.content.style.setProperty("--bo-graph-scale", String(this.scale))
    this.content.style.setProperty("--bo-graph-pan-x", `${Math.round(this.pan.x)}px`)
    this.content.style.setProperty("--bo-graph-pan-y", `${Math.round(this.pan.y)}px`)
    if (this.readout) this.readout.textContent = `${zoomPercent(this.scale)}%`
    this.controls.forEach((button) => {
      const action = button.dataset.graphZoom
      if (action === "in") button.disabled = this.scale >= MAX_ZOOM
      else if (action === "out") button.disabled = this.scale <= MIN_ZOOM
    })
  }

  contentSize() {
    const rect = this.content?.getBoundingClientRect?.()
    // Un-scale the measured box so fit/clamp reason about intrinsic content size.
    return rect ? { width: rect.width / this.scale, height: rect.height / this.scale } : { width: 0, height: 0 }
  }

  viewportSize() {
    const rect = this.viewport?.getBoundingClientRect?.()
    return rect ? { width: rect.width, height: rect.height } : { width: 0, height: 0 }
  }

  // --- selection / highlight ---------------------------------------------

  handleFocusIn(event) {
    const card = event.target.closest("[data-graph-node]")
    if (!card) return
    this.focused = card.dataset.graphNode
    this.applyHighlight()
  }

  handleFocusOut(event) {
    const card = event.target.closest("[data-graph-node]")
    if (!card) return
    // Only clear when focus actually leaves this card.
    if (this.viewport.contains(event.relatedTarget) && event.relatedTarget?.closest("[data-graph-node]")) return
    this.focused = null
    this.applyHighlight()
  }

  handlePointerOver(event) {
    const card = event.target.closest("[data-graph-node]")
    if (!card) return
    this.hovered = card.dataset.graphNode
    this.applyHighlight()
  }

  handlePointerOut(event) {
    const card = event.target.closest("[data-graph-node]")
    if (!card || card.contains(event.relatedTarget)) return
    this.hovered = null
    this.applyHighlight()
  }

  handleCardClick(event) {
    // The native context trigger keeps its own behavior; a background card tap
    // toggles persistent selection (touch/pointer parity with keyboard focus).
    if (event.target.closest("[data-graph-context]")) return
    const card = event.target.closest("[data-graph-node]")
    if (!card) return
    const id = card.dataset.graphNode
    this.selected = this.selected === id ? null : id
    this.applyHighlight()
  }

  handleKeydown(event) {
    const card = event.target.closest("[data-graph-node]")

    if (event.key === "Escape") {
      // Escape clears a pinned selection; focus stays put so the user keeps
      // their place. With nothing pinned, defer to default handling.
      if (!this.selected) return
      this.selected = null
      this.applyHighlight()
      this.announce("Selection cleared")
      return
    }

    if (card && event.key === "Enter" && event.target === card) {
      const trigger = card.querySelector("[data-graph-context]")
      if (trigger) {
        event.preventDefault()
        trigger.click()
      }
      return
    }

    if (card && (event.key === " " || event.key === "Spacebar")) {
      event.preventDefault()
      const id = card.dataset.graphNode
      this.selected = this.selected === id ? null : id
      this.applyHighlight()
      return
    }

    if (card && ["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp", "Home", "End"].includes(event.key)) {
      event.preventDefault()
      this.moveFocus(card, event.key)
      return
    }

    // Keyboard pan/zoom when the canvas region itself holds focus.
    if (event.target === this.viewport) this.handleCanvasKeys(event)
  }

  handleCanvasKeys(event) {
    const pans = { ArrowRight: [-PAN_STEP, 0], ArrowLeft: [PAN_STEP, 0], ArrowDown: [0, -PAN_STEP], ArrowUp: [0, PAN_STEP] }
    if (pans[event.key]) {
      event.preventDefault()
      this.panBy(...pans[event.key])
    } else if (event.key === "+" || event.key === "=") {
      event.preventDefault()
      this.setZoom(stepZoom(this.scale, 1), "keys")
    } else if (event.key === "-" || event.key === "_") {
      event.preventDefault()
      this.setZoom(stepZoom(this.scale, -1), "keys")
    } else if (event.key === "0") {
      event.preventDefault()
      this.resetView()
    }
  }

  moveFocus(card, key) {
    const index = this.cards.indexOf(card)
    if (index === -1) return
    let next = index
    if (key === "ArrowRight" || key === "ArrowDown") next = Math.min(this.cards.length - 1, index + 1)
    else if (key === "ArrowLeft" || key === "ArrowUp") next = Math.max(0, index - 1)
    else if (key === "Home") next = 0
    else if (key === "End") next = this.cards.length - 1
    this.cards[next]?.focus?.()
  }

  activeTarget() {
    return this.hovered || this.focused || this.selected
  }

  applyHighlight() {
    const target = this.activeTarget()
    const chain = this.chainSet(target)

    for (const card of this.cards) {
      const id = card.dataset.graphNode
      const inChain = chain.has(id)
      card.classList.toggle("is-graph-active", id === target)
      card.classList.toggle("is-graph-selected", id === this.selected)
      card.classList.toggle("is-graph-chain", inChain && id !== target)
      card.classList.toggle("is-graph-dimmed", Boolean(target) && !inChain)
      if (id === this.selected) card.setAttribute("aria-current", "true")
      else card.removeAttribute("aria-current")
    }

    this.highlightEdges(chain, target)
    if (target && (target === this.selected || target === this.focused)) this.announceChain(target)
  }

  chainSet(target) {
    if (!target) return new Set()
    const card = this.cardById(target)
    if (!card) return new Set()
    const up = tokens(card.dataset.graphUpstream)
    const down = tokens(card.dataset.graphDownstream)
    return new Set([target, ...up, ...down])
  }

  highlightEdges(chain, target) {
    const svg = this.root.querySelector("[data-layout-edges]")
    if (!svg) return
    const active = Boolean(target)
    for (const path of svg.querySelectorAll("[data-layout-edge-path]")) {
      const edge = this.edgeEndpoints(path.dataset.layoutEdgePath)
      const connected = active && edge && chain.has(edge.source) && chain.has(edge.target)
      path.classList.toggle("is-graph-chain", connected)
      path.classList.toggle("is-graph-dimmed", active && !connected)
    }
  }

  edgeEndpoints(edgeId) {
    const li = this.root.querySelector(`[data-layout-edge-id="${cssEscape(edgeId)}"]`)
    if (!li) return null
    return { source: li.dataset.layoutEdgeSource, target: li.dataset.layoutEdgeTarget }
  }

  cardById(id) {
    return this.cards.find((card) => card.dataset.graphNode === id) || null
  }

  // --- announcements (coalesced) -----------------------------------------

  announceChain(target) {
    const card = this.cardById(target)
    if (!card) return
    const up = tokens(card.dataset.graphUpstream).length
    const down = tokens(card.dataset.graphDownstream).length
    this.announce(`${card.dataset.graphNode}: ${up} upstream, ${down} downstream`)
  }

  // Coalesce rapid updates into a single polite announcement so screen readers
  // are not flooded during pan/zoom or fast card traversal.
  announce(message) {
    if (!this.announceRegion) return
    this.pendingAnnouncement = message
    if (this.announceTimer) this.win.clearTimeout(this.announceTimer)
    this.announceTimer = this.win.setTimeout(() => {
      this.announceTimer = null
      if (this.destroyed || this.pendingAnnouncement === null) return
      this.announceRegion.textContent = this.pendingAnnouncement
      this.pendingAnnouncement = null
    }, 160)
  }
}

function tokens(value) {
  return typeof value === "string" && value.length > 0 ? value.split(" ").filter(Boolean) : []
}

function cssEscape(value) {
  if (typeof value !== "string") return ""
  if (typeof CSS !== "undefined" && typeof CSS.escape === "function") return CSS.escape(value)
  return value.replace(/["\\\]]/g, "\\$&")
}

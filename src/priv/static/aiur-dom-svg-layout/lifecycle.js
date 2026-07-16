import { errorCode, matchesLayoutContext, now, safeCode, validateLayoutResult } from "./protocol.js"
import { layoutAssetUrls, measureLayout, readRootContext } from "./measurement.js"
import { applyFallback, applyLayout, clearVisualLayout, setLayoutHealth } from "./renderer.js"

export class DomSvgLayoutAdapter {
  constructor(element, options, hookInstance) {
    this.element = element
    this.options = options
    this.hookInstance = hookInstance
    this.hookCount = Number(element.dataset.layoutHookCount || 0) + 1
    this.destroyed = false
    this.layoutGeneration = 0
    this.measurementVersion = 0
    this.ignoringResizeObservations = false
    this.resizeObservationEpoch = 0
    this.scheduled = false
    this.pendingReasons = new Set()
    this.client = null
    this.clientPromise = null
    this.clientAssetKey = null
    this.clientEpoch = 0
    this.resizeObserver = null
    this.themeObserver = null
    this.fonts = null
    this.onWindowResize = () => this.requestRemeasure("resize")
    this.onFontLoad = () => this.requestRemeasure("font")
  }

  mount() {
    this.restoreHookMarkers()
    this.installObservers()
    this.configureClient()
    this.scheduleLayout("initial")
    this.notify("mounted")
  }

  updated() {
    this.restoreHookMarkers()
    this.refreshObservedNodes()
    this.scheduleLayout("updated")
  }

  invalidate() {
    this.measurementVersion += 1
    clearVisualLayout(this.element)
  }

  destroy() {
    if (this.destroyed) return

    this.destroyed = true
    this.clientEpoch += 1
    this.resizeObserver?.disconnect()
    this.resizeObserver = null
    this.themeObserver?.disconnect()
    this.themeObserver = null
    this.window().removeEventListener("resize", this.onWindowResize)
    this.fonts?.removeEventListener?.("loadingdone", this.onFontLoad)
    this.fonts = null
    this.disposeClient()
    this.notify("destroyed")
  }

  installObservers() {
    const createResizeObserver = this.options.createResizeObserver || ((callback) => new ResizeObserver(callback))
    if (typeof ResizeObserver === "function" || this.options.createResizeObserver) {
      this.resizeObserver = createResizeObserver(() => {
        if (!this.ignoringResizeObservations) this.requestRemeasure("resize-observer")
      })
      this.refreshObservedNodes()
    }

    this.window().addEventListener("resize", this.onWindowResize)
    this.fonts = this.document().fonts
    this.fonts?.addEventListener?.("loadingdone", this.onFontLoad)
    if (this.fonts?.ready && typeof this.fonts.ready.then === "function") {
      this.fonts.ready.then(() => this.requestRemeasure("font-ready")).catch(() => {})
    }

    const createMutationObserver = this.options.createMutationObserver || ((callback) => new MutationObserver(callback))
    if (typeof MutationObserver === "function" || this.options.createMutationObserver) {
      this.themeObserver = createMutationObserver(() => this.requestRemeasure("theme"))
      this.themeObserver.observe(this.document().documentElement, { attributes: true, attributeFilter: ["class", "data-theme", "style"] })
    }
  }

  refreshObservedNodes() {
    if (!this.resizeObserver || this.destroyed) return

    this.resizeObserver.disconnect()
    this.resizeObserver.observe(this.element)
    this.element.querySelectorAll("[data-layout-node]").forEach((card) => this.resizeObserver.observe(card))
  }

  requestRemeasure(source) {
    if (this.destroyed) return

    this.measurementVersion += 1
    this.notify("remeasure", { source })
    this.scheduleLayout(source)
  }

  scheduleLayout(reason) {
    if (this.destroyed) return

    this.pendingReasons.add(reason)
    if (this.scheduled) return

    this.scheduled = true
    queueMicrotask(() => {
      this.scheduled = false
      const reasons = [...this.pendingReasons]
      this.pendingReasons.clear()
      this.requestLayout(reasons)
    })
  }

  requestLayout(reasons) {
    if (this.destroyed) return

    this.configureClient()
    const clientEpoch = this.clientEpoch

    this.clientPromise?.then((client) => {
      if (!client || this.destroyed || clientEpoch !== this.clientEpoch) return

      const measured = this.measure(clientEpoch)
      if (!measured) return this.fallback("measurement_invalid")

      const { context, request } = measured
      this.notify("request", { reasons, request })
      setLayoutHealth(this.element, "measuring")
      client.layout(request).then((response) => {
        if (!this.canApply(context, request)) return this.discard(response)
        if (!validateLayoutResult(response, request)) return this.fallback("malformed_geometry")
        if (response.type === "error") return this.fallback(response.error?.code || "worker_failed")
        this.suppressResizeObservations()
        if (!applyLayout(this.element, response, measured, this.hookInstance)) return this.fallback("malformed_geometry")
      }).catch((error) => {
        if (this.canApply(context, request)) this.fallback(errorCode(error, "worker_failed"))
      })
    })
  }

  configureClient() {
    const urls = layoutAssetUrls(this.element)
    const assetKey = urls ? `${urls.clientUrl}\u0000${urls.workerUrl}\u0000${urls.engineUrl}` : ""
    if (assetKey === this.clientAssetKey && this.clientPromise) return

    this.disposeClient()
    this.clientAssetKey = assetKey
    const clientEpoch = ++this.clientEpoch
    this.clientPromise = this.createClient(urls)
      .then((client) => {
        if (this.destroyed || clientEpoch !== this.clientEpoch) {
          client?.dispose?.()
          this.notify("client_disposed", { reason: "superseded" })
          return null
        }

        this.client = client
        return client
      })
      .catch((error) => {
        if (!this.destroyed && clientEpoch === this.clientEpoch) {
          this.clientPromise = null
          this.clientAssetKey = null
          this.fallback(errorCode(error, "worker_start_failed"))
        }

        return null
      })
  }

  async createClient(urls) {
    if (!urls) throw new Error("asset_url_invalid")
    if (typeof this.options.clientFactory === "function") return this.options.clientFactory(urls)

    const module = await import(urls.clientUrl)
    return module.createLayoutWorkerClient({ workerUrl: urls.workerUrl, engineUrl: urls.engineUrl })
  }

  measure(clientEpoch) {
    this.suppressResizeObservations()
    const measurementVersion = ++this.measurementVersion
    const layoutGeneration = ++this.layoutGeneration
    const measured = measureLayout(this.element, { clientEpoch, layoutGeneration, measurementVersion })
    return measured ? { ...measured, startedAt: now() } : null
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
    this.notify("discarded")
  }

  fallback(reason) {
    if (this.destroyed) return

    this.suppressResizeObservations()
    applyFallback(this.element, reason)
    this.notify("fallback", { reason })
  }

  disposeClient() {
    if (!this.client) return

    this.client.dispose?.()
    this.client = null
    this.notify("client_disposed", { reason: "destroyed" })
  }

  restoreHookMarkers() {
    this.element.dataset.layoutHookInstance = this.hookInstance
    this.element.dataset.layoutHookCount = String(this.hookCount)
  }

  notify(event, detail = {}) {
    this.element.dispatchEvent(new CustomEvent("aiur:layout-lifecycle", {
      bubbles: true,
      detail: {
        event,
        source: typeof detail.source === "string" ? safeCode(detail.source) : null,
        reason: typeof detail.reason === "string" ? safeCode(detail.reason) : null
      }
    }))

    try {
      this.options.onLifecycle?.(event, detail)
    } catch {
      // Observations must not affect semantic fallback or layout health.
    }
  }

  suppressResizeObservations() {
    this.ignoringResizeObservations = true
    const epoch = ++this.resizeObservationEpoch
    const release = () => {
      if (epoch === this.resizeObservationEpoch) this.ignoringResizeObservations = false
    }
    const requestFrame = this.window().requestAnimationFrame || ((callback) => queueMicrotask(callback))
    requestFrame(release)
  }

  window() {
    return this.options.window || window
  }

  document() {
    return this.options.document || document
  }
}

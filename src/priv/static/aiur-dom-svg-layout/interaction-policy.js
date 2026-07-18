// Pure, DOM-free transform policy for the Build Order graph interaction hook.
//
// The hook applies these transforms and reports state; it never invents graph
// adjacency here. Keeping the math pure makes zoom bounds, fit, and pan clamping
// independently testable.

export const MIN_ZOOM = 0.4
export const MAX_ZOOM = 1.6
export const ZOOM_STEP = 0.2
export const PAN_STEP = 48
// How far past the viewport edge the content may be panned, as a fraction of the
// viewport, so a node is always recoverable and the canvas never fully escapes.
const OVERSCROLL = 0.5

export function clampZoom(value) {
  const scale = Number(value)
  if (!Number.isFinite(scale)) return 1
  return Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, scale))
}

export function stepZoom(current, direction) {
  const step = Math.sign(direction) * ZOOM_STEP
  // Round to the step grid so repeated +/- always land on tidy 20% stops.
  const next = Math.round((clampZoom(current) + step) / ZOOM_STEP) * ZOOM_STEP
  return clampZoom(next)
}

export function fitZoom(content, viewport) {
  if (!positive(content?.width) || !positive(content?.height) || !positive(viewport?.width) || !positive(viewport?.height)) {
    return 1
  }

  // Shrink-to-fit only: fitting a small graph should not blow it up past 100%.
  const scale = Math.min(1, viewport.width / content.width, viewport.height / content.height)
  return clampZoom(scale)
}

export function clampPan(pan, content, viewport, scale) {
  const zoom = clampZoom(scale)
  const x = finite(pan?.x)
  const y = finite(pan?.y)

  if (!positive(content?.width) || !positive(viewport?.width)) return { x, y }

  return {
    x: clampAxis(x, content.width * zoom, viewport.width),
    y: clampAxis(y, content.height * zoom, viewport.height)
  }
}

export function zoomPercent(scale) {
  return Math.round(clampZoom(scale) * 100)
}

function clampAxis(value, contentExtent, viewportExtent) {
  const overscroll = viewportExtent * OVERSCROLL

  if (contentExtent <= viewportExtent) {
    // Content fits: allow gentle recentering but keep it anchored near origin.
    return Math.min(overscroll, Math.max(-overscroll, value))
  }

  const min = viewportExtent - contentExtent - overscroll
  const max = overscroll
  return Math.min(max, Math.max(min, value))
}

function positive(value) {
  return Number.isFinite(value) && value > 0
}

function finite(value) {
  return Number.isFinite(value) ? value : 0
}

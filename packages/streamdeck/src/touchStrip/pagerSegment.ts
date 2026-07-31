/**
 * Pager touch-strip segment view-model — real window count and current window.
 *
 * The strip's fourth segment is the pager: "MORE AGENTS", a row of window dots
 * with the current one filled, and a label. In `cmd` mode this segment is
 * repurposed to "CONTROLLING" plus the active ticket id, so the pager dots only
 * apply to the default (`grid`) mode; the dot math here is mode-independent and
 * the painter decides when to use it.
 *
 * A "window" is one page of agents shown across the strip/deck. How many agents
 * fit per window, and which window is currently focused, are navigation facts
 * owned by the device controller/transport (#1354) — this module does not own
 * or store that state. It is a PURE projection: given a real agent count (from
 * the #1346 fleet projection), a per-window capacity, and the focused window
 * index, it computes how many dots to draw and which one is filled. Like
 * `geometry.ts`, it is arithmetic the painter needs regardless of whether the
 * strip is ultimately painted through OpenDeck's `setFeedbackLayout` (#1342's
 * layout fork) or via direct `0x0C` region writes.
 */

/** Render-ready pager state: the dot row and the focused index. */
export interface PagerModel {
  /** Total windows (dots) needed to page through every agent; always >= 1. */
  readonly windowCount: number;
  /** Zero-based index of the filled dot; clamped into `0..windowCount-1`. */
  readonly currentWindow: number;
  /** Per-dot fill state, left to right; exactly `windowCount` entries. */
  readonly dots: readonly boolean[];
  /** True when more than one window exists (the pager is meaningful). */
  readonly hasMultiple: boolean;
}

function toPositiveInt(value: number, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  const floored = Math.floor(value);
  return floored < 0 ? 0 : floored;
}

/**
 * Build the pager model. `agentCount` is the real fleet size, `perWindow` the
 * number of agents shown per window (must be >= 1; non-positive is treated as
 * 1), and `currentWindow` the focused window index (clamped into range).
 *
 * With zero agents there is still exactly one window so the strip has a stable
 * single dot rather than an empty row.
 */
export function pagerModel(
  agentCount: number,
  perWindow: number,
  currentWindow: number,
): PagerModel {
  const agents = toPositiveInt(agentCount, 0);
  const capacity = Math.max(1, toPositiveInt(perWindow, 1));
  const windowCount = Math.max(1, Math.ceil(agents / capacity));

  const requested = toPositiveInt(currentWindow, 0);
  const clamped = Math.min(requested, windowCount - 1);

  const dots = Array.from({ length: windowCount }, (_unused, i) => i === clamped);

  return {
    windowCount,
    currentWindow: clamped,
    dots,
    hasMultiple: windowCount > 1,
  };
}

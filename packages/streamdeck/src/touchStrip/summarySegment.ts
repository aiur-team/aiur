/**
 * Summary touch-strip segment view-model — the first segment in `grid` mode.
 *
 * Segment one shows the Aiur logo, a live/remaining agent count ("N live /
 * M left"), and a Build progress mini-bar with an ETA. Like the other segment
 * view-models (`providerSegment.ts`, `pagerSegment.ts`) this layer is pure and
 * render-path independent: it turns real fleet + build-order facts into the
 * small, deterministic shape a painter consumes, and invents nothing. When the
 * build order is unknown it reports `build: null` and a zero-length bar rather
 * than a fabricated 0%.
 *
 * `live` and `remaining` come from the #1346 fleet projection; the build
 * progress (`completed` / `total` tickets and an ETA) comes from the same
 * projection's build-order view. This module only reduces and clamps them.
 */

/** Build-order progress as projected: tickets done, total, and an ETA. */
export interface BuildProgressInput {
  readonly completed?: number | null;
  readonly percent?: number | null;
  readonly eta_seconds?: number | null;
  readonly total?: number;
  /** Estimated seconds until the build order completes, when known. */
  readonly etaSeconds?: number | null;
}

/** Render-ready build mini-bar: a 0..1 fraction and a short ETA label. */
export interface BuildProgress {
  readonly completed: number | null;
  readonly total: number;
  /** Producer percent, or legacy completed / total; null when unknown. */
  readonly fraction: number | null;
  /** Compact ETA like "2m" or "1h 5m"; null when no ETA was projected. */
  readonly etaLabel: string | null;
}

/** Render-ready model for the summary segment. */
export interface SummaryModel {
  readonly build_status?: "ok" | "none" | "unavailable";
  /** Number of live (running) agents; clamped to >= 0. */
  readonly live: number;
  /** Number of agents/tickets still queued; clamped to >= 0. */
  readonly remaining: number;
  /** Build mini-bar, or null when no build order is in progress. */
  readonly build: BuildProgress | null;
}

function toCount(value: number | null | undefined): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  const floored = Math.floor(value);
  return floored < 0 ? 0 : floored;
}

/**
 * Format a non-negative second count as a compact ETA. Sub-minute rounds up to
 * "1m" so an imminent finish never reads as "0m"; returns null for a null or
 * negative input.
 */
export function formatEta(etaSeconds: number | null | undefined): string | null {
  if (typeof etaSeconds !== "number" || !Number.isFinite(etaSeconds) || etaSeconds < 0) {
    return null;
  }
  const totalMinutes = Math.max(1, Math.ceil(etaSeconds / 60));
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours === 0) return `${minutes}m`;
  if (minutes === 0) return `${hours}h`;
  return `${hours}h ${minutes}m`;
}

function toBuildProgress(build: BuildProgressInput | null | undefined): BuildProgress | null {
  if (build == null || typeof build !== "object") return null;
  const total = toCount(build.total);
  // With no total there is no meaningful bar to draw.
  if (total <= 0) return null;
  const completed = build.completed === null ? null : Math.min(total, toCount(build.completed));
  const fraction = build.percent === null ? null
    : typeof build.percent === "number" && Number.isFinite(build.percent)
      ? Math.max(0, Math.min(1, build.percent / 100))
      : completed === null ? null : completed / total;
  return {
    completed,
    total,
    fraction,
    etaLabel: formatEta(build.eta_seconds ?? build.etaSeconds ?? null),
  };
}

/**
 * Build the summary segment model from real fleet + build-order facts. Returns
 * a valid model with `build: null` when no build order is running — never a
 * fabricated bar.
 */
export function summaryModel(
  live: number,
  remaining: number,
  build?: BuildProgressInput | null,
  build_status?: SummaryModel["build_status"],
): SummaryModel {
  return {
    build_status,
    live: toCount(live),
    remaining: toCount(remaining),
    build: toBuildProgress(build),
  };
}

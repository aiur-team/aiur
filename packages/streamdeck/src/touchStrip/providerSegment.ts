/**
 * Claude/Codex touch-strip segment view-model — real provider usage, no
 * invented numbers.
 *
 * The strip's second and third segments show, respectively, Claude and Codex
 * usage. Their only sanctioned data source is `Aiur.ProviderMeterProjection`,
 * surfaced to external controllers by the Stream Deck projection channel
 * (#1346). This module turns one provider's projected meter into the small,
 * render-ready shape the segment painter consumes. It invents nothing: every
 * percentage and reset time comes straight from an observed window.
 *
 * This layer is deliberately transport- and render-path independent. Whether
 * the strip is ultimately painted through OpenDeck's `setFeedbackLayout`
 * (#1342's layout fork) or via direct `0x0C` region writes, both paths need the
 * same two facts per provider — a session window and a weekly window, each with
 * a used percentage and a reset time — so this view-model is common to both.
 *
 * ## Payload shape (from the #1346 projection)
 *
 * `usage.<provider>` is the map produced by
 * `AiurWeb.StreamdeckProjection.provider_meter/1`:
 *
 * ```
 * { provider, state, observed_at, age_seconds, auth_mode, plan,
 *   freshness, health, windows }
 * ```
 *
 * `windows` is keyed by an opaque `limit_id` (e.g. `"session"`, `"5h"`,
 * `"7d"`); each value carries `used_percent`, `resets_at`, and — when known —
 * `duration_minutes`. We classify session vs weekly by duration rather than by
 * label string, because the label is provider-defined and not a stable
 * contract: the shortest-duration window is the session, the longest is the
 * weekly.
 *
 * ## Duration-less providers
 *
 * Not every adapter populates `duration_minutes`. Codex does
 * (`windowDurationMins`), but Claude's app-server adapter emits a single
 * `"rate-limit"` window with `used_percent`/`resets_at` and no duration
 * (`src/lib/aiur/claude/rate_limit_adapter.ex`). Duration is the ordering key,
 * so a lone duration-less window cannot be ordered against a peer — but it is
 * still the provider's one real reading. We therefore fall back to treating a
 * SINGLE unclassifiable window as the session (never a fabricated weekly), so
 * Claude shows its real usage instead of a permanent "awaiting data". Two or
 * more duration-less windows stay ambiguous and are reported as no data rather
 * than guessed.
 */

/** One observed rate-limit window, as projected. */
export interface ProviderMeterWindow {
  readonly used_percent?: number;
  readonly resets_at?: string;
  readonly duration_minutes?: number;
}

/** One provider's projected meter (the subset the segment needs). */
export interface ProviderMeter {
  readonly provider?: string;
  readonly state?: string;
  readonly freshness?: string;
  readonly windows?: Readonly<Record<string, ProviderMeterWindow>>;
}

/** A single window reduced to what the segment renders. */
export interface UsageWindow {
  /** Used percentage, clamped to 0..100. */
  readonly usedPercent: number;
  /** ISO-8601 reset instant, or null when the window did not report one. */
  readonly resetsAt: string | null;
}

/**
 * Render-ready model for a Claude or Codex segment. `session` / `weekly` are
 * null when no window of that role was observed; `hasData` is true only when at
 * least one is present, so the painter can show an "awaiting data" state rather
 * than a fabricated 0%.
 */
export interface ProviderSegmentModel {
  readonly provider: string | null;
  readonly session: UsageWindow | null;
  readonly weekly: UsageWindow | null;
  readonly freshness: string | null;
  readonly hasData: boolean;
}

function clampPercent(value: number | undefined): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  if (value < 0) return 0;
  if (value > 100) return 100;
  return value;
}

function toUsageWindow(window: ProviderMeterWindow): UsageWindow {
  return {
    usedPercent: clampPercent(window.used_percent),
    resetsAt: typeof window.resets_at === "string" ? window.resets_at : null,
  };
}

/**
 * Classify the observed windows into a session (shortest duration) and a weekly
 * (longest duration) window. Windows without a `duration_minutes` cannot be
 * ordered and are ignored for classification.
 */
function classifyWindows(windows: Readonly<Record<string, ProviderMeterWindow>>): {
  session: ProviderMeterWindow | null;
  weekly: ProviderMeterWindow | null;
} {
  const all = Object.values(windows);
  let session: ProviderMeterWindow | null = null;
  let weekly: ProviderMeterWindow | null = null;
  let sessionDuration = Infinity;
  let weeklyDuration = -Infinity;

  for (const window of all) {
    const duration = window.duration_minutes;
    if (typeof duration !== "number" || !Number.isFinite(duration)) continue;
    if (duration < sessionDuration) {
      sessionDuration = duration;
      session = window;
    }
    if (duration > weeklyDuration) {
      weeklyDuration = duration;
      weekly = window;
    }
  }

  // Duration-less fallback: a provider (Claude) may report exactly one window
  // with no `duration_minutes`. There is nothing to order it against, but it is
  // the provider's one real reading, so treat it as the session. Only applies
  // when the duration pass classified nothing AND there is a single window —
  // multiple duration-less windows stay ambiguous, never guessed.
  if (session === null && weekly === null && all.length === 1) {
    session = all[0];
  }

  // A single classifiable window is the session, not simultaneously the weekly.
  // Reference identity is safe here: the strict `<` / `>` comparisons above keep
  // the first-seen window on ties, so with only one classifiable window — or
  // several of equal duration — `session` and `weekly` point at the SAME object
  // and this nulls the duplicate weekly. Two windows of *distinct* durations
  // always resolve to two different objects and both survive.
  if (session !== null && session === weekly) {
    weekly = null;
  }

  return { session, weekly };
}

/**
 * Build the render-ready segment model for one provider's projected meter.
 * Returns an empty-but-valid model (nulls, `hasData: false`) when the meter is
 * missing or reports no classifiable windows — never a fabricated reading.
 */
export function providerSegmentModel(meter: ProviderMeter | null | undefined): ProviderSegmentModel {
  if (meter == null || typeof meter !== "object") {
    return { provider: null, session: null, weekly: null, freshness: null, hasData: false };
  }

  const windows = meter.windows ?? {};
  const { session, weekly } = classifyWindows(windows);

  return {
    provider: typeof meter.provider === "string" ? meter.provider : null,
    session: session === null ? null : toUsageWindow(session),
    weekly: weekly === null ? null : toUsageWindow(weekly),
    freshness: typeof meter.freshness === "string" ? meter.freshness : null,
    hasData: session !== null || weekly !== null,
  };
}

/**
 * Grid-mode provider view-model: which providers the strip shows, and where.
 *
 * The strip's centre used to be two hard-coded 200x100 segments, Claude and
 * Codex. The daemon emits a meter per *configured* provider family, and the
 * strip showed exactly two of them wherever that list happened to land: a fleet
 * running neither Claude nor Codex got two permanent "Awaiting data" panels for
 * providers it does not use, and any family beyond those two — the registry is
 * open, and adding one is a server-side change alone — had a real meter that no
 * pixel on the deck could show.
 *
 * This module turns the projected `usage` map into the rows the painter draws
 * and decides nothing about pixels. Two shapes come out of it:
 *
 *   - **exactly two providers** — one row each, drawn in the two 200-wide
 *     segments, which is today's look and stays today's look;
 *   - **three or more** — the centre two segments merge into one 400x100 area
 *     with one row per provider.
 *
 * Ordering is alphabetical by provider key rather than the map's own order. The
 * daemon's map is JSON-encoded from an Elixir map, whose iteration order is an
 * implementation detail that can change with the number of keys; letting it
 * through would reorder the strip for no operator-visible reason.
 */
import { providerSegmentModel, type ProviderMeter, type ProviderSegmentModel } from "./providerSegment.js";

/** One provider's row: the name to print and its meter reading. */
export interface ProviderPanelRow {
  readonly label: string;
  readonly model: ProviderSegmentModel;
}

/** The wide panel's content: the rows to draw and how many were left out. */
export interface ProviderPanelModel {
  readonly rows: readonly ProviderPanelRow[];
  /** Providers not given a row; 0 when every provider is shown. */
  readonly overflow: number;
}

/**
 * Most rows the 400x100 area can carry and stay legible at arm's length.
 *
 * At five rows the type is already down to 8px; a sixth would put glyph
 * descenders through the bar above it. Beyond this the panel drops rows rather
 * than shrinking further, which is the one failure mode that stays honest —
 * unreadable rows look like data but are not.
 */
export const MAX_PROVIDER_ROWS = 5;

/** Below this many providers the strip keeps the two fixed 200-wide segments. */
export const WIDE_PANEL_THRESHOLD = 3;

/** Session usage, or -1 for a provider that reported nothing. */
const constraint = (row: ProviderPanelRow): number => row.model.session?.usedPercent ?? -1;

/**
 * Reduce the projected `usage` map to one row per provider, alphabetically.
 *
 * Every key the daemon sent gets a row, including one whose value is not a
 * meter at all. Dropping it would hide a configured provider *and* silently
 * change the layout: losing one of three takes the strip back under
 * {@link WIDE_PANEL_THRESHOLD}, so a broken meter would render as an ordinary
 * two-provider fleet. `providerSegmentModel` reports no data for it, so the row
 * reads "Awaiting data" — the same honest silence a provider whose meter has
 * not reported yet gets.
 */
export const providerRows = (usage: Readonly<Record<string, unknown>>): readonly ProviderPanelRow[] =>
  Object.keys(usage)
    .sort()
    .map((key) => ({
      label: key,
      model: providerSegmentModel(typeof usage[key] === "object" ? (usage[key] as ProviderMeter | null) : null),
    }));

/**
 * Choose the rows the wide panel draws.
 *
 * When more providers are configured than fit, the ones kept are those closest
 * to their session limit — a provider at 4% is the one an operator can afford
 * not to see — but they are drawn back in the caller's order, so a usage tick
 * never reshuffles the panel under the operator's eyes. The dropped count is
 * reported so the panel can say so instead of silently under-reporting the
 * fleet's exposure.
 */
export const providerPanelModel = (rows: readonly ProviderPanelRow[]): ProviderPanelModel => {
  if (rows.length <= MAX_PROVIDER_ROWS) return { rows, overflow: 0 };
  const kept = new Set(
    [...rows]
      .sort((left, right) => constraint(right) - constraint(left))
      .slice(0, MAX_PROVIDER_ROWS - 1),
  );
  return { rows: rows.filter((row) => kept.has(row)), overflow: rows.length - (MAX_PROVIDER_ROWS - 1) };
};

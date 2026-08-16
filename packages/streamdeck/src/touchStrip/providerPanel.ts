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
 *     showing a fixed-size window of {@link VISIBLE_PROVIDER_ROWS} rows that
 *     knob 2 scrolls through.
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

/** The wide panel's content: the visible window, and where it sits in the list. */
export interface ProviderPanelModel {
  /** The rows to draw: at most {@link VISIBLE_PROVIDER_ROWS} of them. */
  readonly rows: readonly ProviderPanelRow[];
  /** Providers configured in total, shown so the panel can say how many. */
  readonly total: number;
  /** True when rows sit before the window — scrolling up reveals more. */
  readonly hasAbove: boolean;
  /** True when rows sit after the window — scrolling down reveals more. */
  readonly hasBelow: boolean;
}

/**
 * Rows the 400x100 area shows at once, at a fixed size.
 *
 * Fixed, not derived from the provider count. Deriving it is what this panel
 * did first: row height, type size and bar height all fell out of how many
 * providers were configured, so a fifth provider silently took every row down
 * to 8px type — a size the two-provider segments had already been widened away
 * from because it could not be read at arm's length. Three rows in 100px leave
 * ~28px each, which is a 20px vendor mark, 13px type and a real bar. Providers
 * past the third are reached by scrolling (knob 2), not by shrinking.
 */
export const VISIBLE_PROVIDER_ROWS = 3;

/** Below this many providers the strip keeps the two fixed 200-wide segments. */
export const WIDE_PANEL_THRESHOLD = 3;

/**
 * The encoder that scrolls the provider list: knob 2, the second of four.
 *
 * Shared by the controller, which turns it into an offset, and the painter,
 * which puts the label over the right knob — a binding those two disagreeing
 * about is a hint pointing at the wrong control, which is worse than no hint.
 * Knob 2 turns are unclaimed in every mode; its *press* is half the demo chord,
 * which is a separate control path (see `DEMO_CHORD`).
 */
export const PROVIDER_SCROLL_ENCODER = 1;

/**
 * Largest first-row index that still fills the panel, and 0 whenever every
 * provider already fits. Scrolling is clamped to it at both ends so a long spin
 * of the encoder does not have to be unwound click for click before the list
 * moves again.
 */
export const maxProviderOffset = (total: number): number => Math.max(0, total - VISIBLE_PROVIDER_ROWS);

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
 * The window of rows the wide panel draws, starting at `offset`.
 *
 * The panel used to keep the providers closest to their session limit and print
 * `+N MORE PROVIDERS` for the rest. That ranking moved with every usage tick and
 * the dropped providers were unreachable: an operator who wanted the one at 4%
 * had no control that would show it. Every provider is now reachable by
 * scrolling, so the order stays the caller's alphabetical one and nothing is
 * dropped.
 *
 * `offset` is normalised and clamped rather than trusted: the provider list is
 * the daemon's, and a provider disappearing between two pushes must not leave
 * the panel showing an empty window. A non-finite offset is treated as the top
 * of the list, because `Math.min`/`Math.max` propagate NaN and `slice(NaN, NaN)`
 * returns nothing — a configured fleet would render as a blank 400x100 area,
 * which is the most misleading thing this panel can show.
 */
export const providerPanelModel = (rows: readonly ProviderPanelRow[], offset: number): ProviderPanelModel => {
  const requested = Number.isFinite(offset) ? Math.trunc(offset) : 0;
  const start = Math.max(0, Math.min(requested, maxProviderOffset(rows.length)));
  return {
    rows: rows.slice(start, start + VISIBLE_PROVIDER_ROWS),
    total: rows.length,
    hasAbove: start > 0,
    hasBelow: start + VISIBLE_PROVIDER_ROWS < rows.length,
  };
};

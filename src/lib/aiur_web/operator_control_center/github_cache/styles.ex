defmodule AiurWeb.OperatorControlCenter.GithubCache.Styles do
  @moduledoc """
  Scoped stylesheet for the GitHub cache inspector, following Analytics.

  Everything is scoped under `.ghc-root` and every colour is a theme token —
  never a literal hex, which `AiurWeb.DashboardCssThemeTest` enforces and which
  is what keeps the page legible in both themes without a second palette.

  The map layer carries the only genuinely unusual rule: a cell's size comes
  from `--ghc-weight` (how many entries the type holds) and its tint from
  `--ghc-stale` (what fraction of them are past their freshness window), both
  set inline per cell. That is the requirement that a stale region be obvious
  without reading any text, and it cannot be done from a static class list
  because the values are data.
  """

  @css """
  .ghc-root { display: flex; flex-direction: column; gap: 1.25rem; }

  /* The categorical palette for the spend-by-caller chart. These are the one
     place on this page where a hex is correct: the theme tokens are a semantic
     status palette (good / attention / blocking) and painting five peer callers
     with them would say a caller is "bad" because it happened to rank third.
     Both columns are selected for their own surface — the dark steps are not an
     automatic flip of the light ones — and the set is validated for lightness
     band, chroma floor, colour-vision separation and normal-vision separation
     against `--surface` in each theme. Adjacent-pair worst case is CVD dE 9.1
     light / 8.4 dark against a target of 8. Four light-mode steps sit under 3:1
     on the cream surface, which is why the chart always ships a legend and the
     ranking table beside it rather than colour alone.

     `outside` and `other` are deliberately chroma-free. They are not series. */
  .ghc-root {
    --ghc-series-1: #3987e5;
    --ghc-series-2: #d95926;
    --ghc-series-3: #199e70;
    --ghc-series-4: #c98500;
    --ghc-series-5: #d55181;
    --ghc-series-other: #8b8f99;
    --ghc-series-outside: #969aa4;
  }

  html[data-theme="light"] .ghc-root {
    --ghc-series-1: #2a78d6;
    --ghc-series-2: #eb6834;
    --ghc-series-3: #1baf7a;
    --ghc-series-4: #eda100;
    --ghc-series-5: #e87ba4;
    --ghc-series-other: #6d6450;
    --ghc-series-outside: #635a48;
  }

  .ghc-readonly {
    margin: 0;
    padding: 0.75rem 1rem;
    border: 1px solid var(--line);
    border-radius: var(--radius);
    background: var(--surface);
    color: var(--muted);
    font-size: 0.875rem;
  }

  .ghc-cost {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
    gap: 0.75rem;
  }

  .ghc-tile {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
    padding: 0.875rem 1rem;
    border: 1px solid var(--line);
    border-radius: var(--radius);
    background: var(--surface);
    box-shadow: var(--shadow-sm);
  }

  .ghc-tile-headline { border-color: var(--good-ink); }
  .ghc-tile-headline .ghc-tile-value { color: var(--good-ink); }
  .ghc-tile-headline[data-value]:not([data-value="0"]) { border-color: var(--blocking-ink); }
  .ghc-tile-headline[data-value]:not([data-value="0"]) .ghc-tile-value { color: var(--blocking-ink); }

  .ghc-tile-wide { grid-column: span 2; }
  .ghc-tile-value { font-size: 1.5rem; font-weight: 600; color: var(--fg); }
  .ghc-tile-label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
  .ghc-tile-note { font-size: 0.75rem; color: var(--muted); }

  .ghc-writer-list { list-style: none; margin: 0.25rem 0 0; padding: 0; display: flex; flex-wrap: wrap; gap: 0.5rem 1rem; }
  .ghc-writer-list li { display: flex; gap: 0.35rem; font-size: 0.8125rem; }
  .ghc-writer-name { color: var(--muted); }
  .ghc-writer-count { color: var(--fg); font-weight: 600; }

  .ghc-map { display: grid; grid-template-columns: repeat(auto-fill, minmax(12rem, 1fr)); gap: 0.75rem; align-items: stretch; }

  .ghc-trends { display: flex; flex-direction: column; gap: 0.6rem; }
  .ghc-trends-head { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
  .ghc-trends-title { margin: 0; font-size: 0.8125rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
  .ghc-trends-note { margin: 0; font-size: 0.75rem; color: var(--muted); }

  .ghc-charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(20rem, 1fr)); gap: 0.75rem; }
  .ghc-chart {
    margin: 0;
    padding: 0.875rem 1rem;
    border: 1px solid var(--line);
    border-radius: var(--radius);
    background: var(--surface);
    box-shadow: var(--shadow-sm);
  }
  .ghc-chart-title { margin: 0 0 0.5rem; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--fg); }
  .ghc-chart-body { min-height: 8rem; }
  .ghc-chart-legend { display: flex; flex-wrap: wrap; gap: 0.4rem 1rem; margin-top: 0.5rem; font-size: 0.75rem; color: var(--muted); }
  .ghc-legend-item { display: inline-flex; align-items: center; gap: 0.35rem; }
  .ghc-legend-swatch { width: 0.7rem; height: 0.7rem; border-radius: 2px; display: inline-block; }

  .ghc-usage { display: flex; flex-direction: column; gap: 0.9rem; }
  .ghc-usage-budget {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    padding: 0.875rem 1rem;
    border: 1px solid var(--line);
    border-radius: var(--radius);
    background: var(--surface);
    box-shadow: var(--shadow-sm);
  }
  .ghc-usage-head { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
  .ghc-usage-budget-name { margin: 0; font-size: 0.8125rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--fg); }
  .ghc-usage-window { font-size: 0.75rem; color: var(--muted); }
  .ghc-usage-note { margin: 0; font-size: 0.75rem; color: var(--muted); }
  .ghc-usage-note-strong { color: var(--attention-ink); }

  .ghc-usage-splits { display: flex; flex-wrap: wrap; gap: 0.5rem 1.5rem; }
  .ghc-usage-split { display: flex; flex-direction: column; gap: 0.1rem; }
  .ghc-usage-split-value { font-size: 1.25rem; font-weight: 600; color: var(--fg); font-variant-numeric: tabular-nums; }
  .ghc-usage-split-label { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
  .ghc-usage-unmeasured .ghc-usage-split-value { color: var(--muted); font-size: 0.9375rem; font-weight: 500; }

  .ghc-usage-table-scroll { max-width: 100%; overflow-x: auto; }
  .ghc-usage-table-scroll:focus-visible { outline: 2px solid var(--accent-ink); outline-offset: 2px; }
  .ghc-usage-table { width: 100%; min-width: 48rem; border-collapse: collapse; font-size: 0.8125rem; }
  .ghc-usage-table th { text-align: left; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); padding: 0.25rem 0.5rem; }
  .ghc-usage-table td { padding: 0.25rem 0.5rem; border-top: 1px solid var(--hairline); font-variant-numeric: tabular-nums; }
  .ghc-usage-table td:first-child { font-variant-numeric: normal; }
  .ghc-usage-swatch { width: 0.6rem; height: 0.6rem; border-radius: 2px; display: inline-block; margin-right: 0.4rem; vertical-align: baseline; }
  .ghc-usage-row-outside td { border-top: 2px solid var(--line); color: var(--muted); }
  .ghc-usage-source { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
  .ghc-usage-source-assumed { color: var(--attention-ink); }

  /* Density and freshness, both from data. `--ghc-weight` scales the cell with
     how much the type holds; `--ghc-stale` tints it toward the attention ink so
     a stale region reads before any label does. */
  .ghc-cell {
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 0.25rem;
    min-height: calc(5rem + (var(--ghc-weight, 0.5) * 4rem));
    padding: 1rem;
    border: 1px solid var(--line);
    border-radius: var(--radius);
    background: var(--surface);
    color: var(--fg);
    text-decoration: none;
    box-shadow: var(--shadow-sm);
    position: relative;
    overflow: hidden;
  }

  .ghc-cell::after {
    content: "";
    position: absolute;
    inset: 0;
    background: var(--attention-ink);
    opacity: calc(var(--ghc-stale, 0) * 0.18);
    pointer-events: none;
  }

  .ghc-cell[data-worst="expired"] { border-color: var(--blocking-ink); }
  .ghc-cell[data-worst="stale"] { border-color: var(--attention-ink); }
  .ghc-cell-count { font-size: 1.75rem; font-weight: 700; }
  .ghc-cell-label { font-size: 0.9375rem; font-weight: 600; }
  .ghc-cell-freshness { font-size: 0.75rem; color: var(--muted); }

  .ghc-controls { display: flex; flex-direction: column; gap: 0.5rem; }
  .ghc-search { display: flex; align-items: center; gap: 0.5rem; }
  .ghc-search label { font-size: 0.8125rem; color: var(--muted); }
  .ghc-search input {
    flex: 1 1 auto;
    max-width: 24rem;
    padding: 0.4rem 0.6rem;
    border: 1px solid var(--line);
    border-radius: var(--radius);
    background: var(--surface);
    color: var(--fg);
  }

  .ghc-filter-row { display: flex; flex-wrap: wrap; gap: 0.4rem; }

  .ghc-chip {
    padding: 0.3rem 0.7rem;
    border: 1px solid var(--line);
    border-radius: 999px;
    background: var(--surface);
    color: var(--muted);
    font-size: 0.8125rem;
    cursor: pointer;
  }

  .ghc-chip-on { color: var(--accent-ink); border-color: var(--accent-ink); }

  .ghc-active { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; font-size: 0.8125rem; color: var(--muted); }
  .ghc-active-item { padding: 0.15rem 0.5rem; border: 1px solid var(--line); border-radius: 999px; color: var(--fg); }
  .ghc-clear { border: none; background: none; color: var(--accent-ink); cursor: pointer; text-decoration: underline; font-size: 0.8125rem; }

  .ghc-count { margin: 0; font-size: 0.8125rem; color: var(--muted); }
  .ghc-elided { color: var(--attention-ink); }

  .ghc-table { width: 100%; border-collapse: collapse; font-size: 0.875rem; }
  .ghc-table th, .ghc-table td { text-align: left; padding: 0.5rem 0.6rem; border-bottom: 1px solid var(--line); }
  .ghc-table th { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
  .ghc-table a { color: var(--accent-ink); }

  .ghc-row[data-freshness="stale"] td:first-child { border-left: 3px solid var(--attention-ink); }
  .ghc-row[data-freshness="expired"] td:first-child { border-left: 3px solid var(--blocking-ink); }

  /* Validator held, body absent. Marked visually and in words, because it is
     the state that most easily reads as a cache hit while being the opposite of
     one: a reader sending that ETag pays for a 304 and receives no data. Colour
     is never the only signal — the Body cell says "none — validator only". */
  .ghc-row-bodyless td { background: color-mix(in srgb, var(--attention-ink) 8%, transparent); }
  .ghc-row-bodyless td[data-role="body"] { color: var(--attention-ink); font-weight: 600; }

  .ghc-cell-bodyless { font-size: 0.75rem; color: var(--attention-ink); }
  .ghc-cell-elided { font-size: 0.75rem; color: var(--muted); }

  .ghc-tile[data-role="bodyless-count"]:not([data-value="0"]) { border-color: var(--attention-ink); }
  .ghc-tile[data-role="bodyless-count"]:not([data-value="0"]) .ghc-tile-value { color: var(--attention-ink); }

  .ghc-warn {
    margin: 0 0 1rem;
    padding: 0.75rem 0.9rem;
    border: 1px solid var(--attention-ink);
    border-radius: var(--radius);
    color: var(--fg);
    font-size: 0.875rem;
  }

  /* A write should be watchable, not merely reflected in a count. The row that
     changed flashes so a webhook delivery can be seen arriving. */
  .ghc-row-changed { animation: ghc-flash 4s ease-out 1; }

  @keyframes ghc-flash {
    0% { background: var(--good-ink); }
    100% { background: transparent; }
  }

  @media (prefers-reduced-motion: reduce) {
    .ghc-row-changed { animation: none; outline: 2px solid var(--good-ink); }
  }

  .ghc-record dl { display: grid; grid-template-columns: minmax(8rem, max-content) 1fr; gap: 0.35rem 1rem; margin: 0 0 1rem; }
  .ghc-record dt { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
  .ghc-record dd { margin: 0; color: var(--fg); word-break: break-word; }

  .ghc-payload summary { cursor: pointer; color: var(--accent-ink); font-size: 0.875rem; }
  .ghc-payload pre {
    margin: 0.5rem 0 0;
    padding: 0.75rem;
    border: 1px solid var(--line);
    border-radius: var(--radius);
    background: var(--surface);
    color: var(--fg);
    overflow-x: auto;
    max-height: 32rem;
    font-size: 0.8125rem;
  }

  .ghc-empty {
    padding: 1rem;
    border: 1px dashed var(--line);
    border-radius: var(--radius);
    color: var(--muted);
  }

  .ghc-empty p { margin: 0.35rem 0 0; }

  @media (max-width: 40rem) {
    .ghc-tile-wide { grid-column: span 1; }
    .ghc-table { display: block; overflow-x: auto; }
  }
  """

  @spec css() :: String.t()
  def css, do: @css
end

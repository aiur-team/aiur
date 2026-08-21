defmodule AiurWeb.OperatorControlCenter.GithubCache.Charts do
  @moduledoc """
  Pure inline-SVG chart builders for the GitHub cache history — the house
  rendering style (no client charting library), the same one the Analytics page
  uses. Each function turns the retained `Aiur.GitHub.CacheHistory` samples into
  a self-contained, theme-reactive `<svg>` string; colours reference CSS custom
  properties so light/dark switch without a redraw.

  Two charts cover "how up to date":

    * `entries_over_time/1` — total entries, how many hold a body, how many are
      validator-only, as lines. A cache that grew then dropped shows up here.
    * `freshness_over_time/1` — the same totals stacked by freshness, so the
      band of a cache that is quietly going stale reads before any number does.

  One covers "what is spending the budget":

    * `spend_over_time/1` — one budget's spend stacked by the caller that
      issued it, with everything this daemon did not issue as the top band.
      The top of the stack is therefore the credential's own `used` figure, so
      the chart reconciles by construction instead of by assertion.

  The x axis is elapsed time since the first retained sample, so the charts say
  what they cover (the live-session ring) rather than pretending to be history
  the sampler never recorded.

  ## Colour

  Caller bands take a five-slot categorical palette, `--ghc-series-1` through
  `--ghc-series-5`, defined per theme in the page's scoped stylesheet and
  validated for colour-vision separation against both surfaces. The slot comes
  from `Aiur.GitHub.QuotaUsage`, which ranks once over the whole retained
  series, so a caller keeps its colour when another overtakes it — colour
  follows the caller, never its rank at one instant. The palette is never
  cycled: a sixth caller folds into the neutral `other` band rather than
  borrowing slot one's hue and claiming to be that caller.

  The `outside` band is neutral and chroma-free on purpose. It is not a series
  competing with the callers; it is the part of the bill none of them explain.
  """

  alias Aiur.GitHub.QuotaUsage

  @w 760

  @doc "Entries over time: total, with body, validator-only."
  @spec entries_over_time([map()]) :: String.t()
  def entries_over_time(samples) when is_list(samples) and length(samples) >= 2 do
    {t0, t1} = domain(samples)
    h = 200
    {ml, mr, mt, mb} = {36, 14, 14, 24}
    pw = @w - ml - mr
    ph = h - mt - mb
    vmax = samples |> Enum.map(& &1.total) |> Enum.max() |> max(1)
    xf = fn t -> ml + (t - t0) / max(t1 - t0, 1) * pw end
    yf = fn v -> mt + ph - v / vmax * ph end

    total = samples |> Enum.map(fn s -> {xf.(s.t_ms), yf.(s.total)} end)
    with_body = samples |> Enum.map(fn s -> {xf.(s.t_ms), yf.(s.with_body)} end)
    bodyless = samples |> Enum.map(fn s -> {xf.(s.t_ms), yf.(s.bodyless)} end)

    inner =
      y_grid(vmax, yf, ml, @w - mr, &to_string(round(&1))) <>
        ~s|<path d="#{line(total)}" fill="none" stroke="var(--fg)" stroke-width="1.6"/>| <>
        ~s|<path d="#{line(with_body)}" fill="none" stroke="var(--good)" stroke-width="1.6"/>| <>
        ~s|<path d="#{line(bodyless)}" fill="none" stroke="var(--attention)" stroke-width="1.6"/>| <>
        x_axis(t0, t1, xf, ml, @w - mr, mt + ph)

    svg(h, inner, "Cache entries over time")
  end

  def entries_over_time(_samples), do: ""

  @doc "The cache's totals stacked by freshness, so staleness is a band not a line."
  @spec freshness_over_time([map()]) :: String.t()
  def freshness_over_time(samples) when is_list(samples) and length(samples) >= 2 do
    {t0, t1} = domain(samples)
    h = 200
    {ml, mr, mt, mb} = {36, 14, 14, 24}
    pw = @w - ml - mr
    ph = h - mt - mb
    vmax = samples |> Enum.map(& &1.total) |> Enum.max() |> max(1)
    xf = fn t -> ml + (t - t0) / max(t1 - t0, 1) * pw end
    yf = fn v -> mt + ph - v / vmax * ph end

    # Bottom of the stack is fresh — the state a cache should mostly be — and
    # each worse bucket sits above it, so the eye reads "green at the bottom,
    # how much red/amber climbed above it".
    layers = [
      {"var(--good)", 0.8, & &1.fresh},
      {"var(--attention)", 0.75, & &1.stale},
      {"var(--blocking)", 0.7, & &1.expired},
      {"var(--faint)", 0.6, & &1.unknown}
    ]

    inner =
      y_grid(vmax, yf, ml, @w - mr, &to_string(round(&1))) <>
        stacked_areas(samples, layers, xf, yf) <>
        x_axis(t0, t1, xf, ml, @w - mr, mt + ph)

    svg(h, inner, "Cache freshness over time")
  end

  def freshness_over_time(_samples), do: ""

  @doc """
  One budget's spend over time, stacked by the caller that issued it.

  Takes a `Aiur.GitHub.QuotaUsage.series/2` projection — which has already
  dropped any sample where the credential's window was not observed — and draws
  its bands bottom-up in the projection's own order. The y scale is the top of
  the stack, which is the window's real spend, so a tall neutral band is
  immediately readable as "most of this bill is not ours".

  Answers `""` for a nil or too-short projection. The page renders its own words
  in that case rather than an empty axis that reads as a measured zero.
  """
  @spec spend_over_time(map() | nil) :: String.t()
  def spend_over_time(%{points: points, bands: bands} = series) when length(points) >= 2 do
    {t0, t1} = spend_domain(points)
    h = 220
    {ml, mr, mt, mb} = {44, 14, 14, 24}
    pw = @w - ml - mr
    ph = h - mt - mb
    vmax = points |> Enum.map(&stack_total(&1, bands)) |> Enum.max() |> max(1)
    xf = fn t -> ml + (t - t0) / max(t1 - t0, 1) * pw end
    yf = fn v -> mt + ph - v / vmax * ph end
    boundary = window_boundary(series, t0, t1)

    inner =
      pre_window_shade(boundary, xf, ml, mt, ph) <>
        y_grid(vmax, yf, ml, @w - mr, &to_string(round(&1))) <>
        spend_bands(points, bands, xf, yf) <>
        current_window_guide(boundary, xf, mt, ph) <>
        x_axis(t0, t1, xf, ml, @w - mr, mt + ph)

    svg(h, inner, chart_label(series))
  end

  def spend_over_time(_series), do: ""

  @doc """
  The CSS custom property a band paints with.

  Caller slots one to five are the validated categorical palette; the folded
  tail and the unissued remainder are neutrals, which is the secondary encoding
  that keeps them from reading as "just another caller".
  """
  @spec band_color(map()) :: String.t()
  def band_color(%{kind: :caller, slot: slot}) when is_integer(slot) and slot >= 1 and slot <= 5,
    do: "var(--ghc-series-#{slot})"

  def band_color(%{kind: :outside}), do: "var(--ghc-series-outside)"
  def band_color(_band), do: "var(--ghc-series-other)"

  # The scope is in the label, never only in the caption: an attributed-only
  # chart read as the whole bill is the mistake this page exists to prevent.
  defp chart_label(%{scope: :attributed, budget: budget} = series),
    do: "#{budget} spend issued by this daemon over time, by caller — not the whole bill#{window_label(series)}"

  defp chart_label(%{budget: budget} = series), do: "#{budget} spend over time, by caller#{window_label(series)}"

  defp window_label(series) do
    if QuotaUsage.spans_previous_window?(series), do: ", with earlier-window history shaded", else: ""
  end

  defp stack_total(point, bands), do: Enum.reduce(bands, 0, &(Map.get(point.values, &1.key, 0) + &2))

  defp spend_domain(points) do
    first = hd(points).t_ms
    last = List.last(points).t_ms
    if last > first, do: {first, last}, else: {first, first + 1}
  end

  # A 2px surface gap between segments, so two adjacent bands never read as one
  # continuous region when their hues are close.
  defp spend_bands(points, bands, xf, yf) do
    zero = Map.new(points, &{&1.t_ms, 0})

    {_cum, out} =
      Enum.reduce(bands, {zero, []}, fn band, {cum, acc} ->
        next = Map.new(points, fn p -> {p.t_ms, Map.get(cum, p.t_ms) + Map.get(p.values, band.key, 0)} end)
        top = Enum.map(points, fn p -> {xf.(p.t_ms), yf.(Map.get(next, p.t_ms))} end)
        bot = points |> Enum.map(fn p -> {xf.(p.t_ms), yf.(Map.get(cum, p.t_ms))} end) |> Enum.reverse()
        total = Map.get(next, List.last(points).t_ms) - Map.get(cum, List.last(points).t_ms)

        path =
          ~s|<g><title>#{escape(band.label)}: #{total} points now</title>| <>
            ~s|<path d="#{poly(top ++ bot)}" fill="#{band_color(band)}" fill-opacity="#{band_opacity(band)}" | <>
            ~s|stroke="var(--surface)" stroke-width="2"/></g>|

        {next, [path | acc]}
      end)

    out |> Enum.reverse() |> Enum.join()
  end

  defp pre_window_shade(boundary, xf, x0, y0, height) do
    case boundary do
      nil ->
        ""

      boundary ->
        width = max(xf.(boundary) - x0, 0)

        ~s|<g data-role="pre-window-history"><title>History before current window</title>| <>
          ~s|<rect x="#{x0}" y="#{y0}" width="#{r2(width)}" height="#{height}" fill="var(--faint)" fill-opacity="0.12"/></g>|
    end
  end

  defp current_window_guide(boundary, xf, y0, height) do
    case boundary do
      nil ->
        ""

      boundary ->
        x = r2(xf.(boundary))
        {label_x, anchor} = if x > @w - 80, do: {x - 4, "end"}, else: {x + 4, "start"}

        ~s|<g data-role="current-window-boundary"><title>Current window begins</title>| <>
          ~s|<line x1="#{x}" x2="#{x}" y1="#{y0}" y2="#{y0 + height}" stroke="var(--muted)" stroke-width="1" stroke-dasharray="4 3"/>| <>
          text(label_x, y0 + 10, "current window", anchor: anchor) <> "</g>"
    end
  end

  defp window_boundary(%{current_window_started_at_ms: boundary} = series, t0, t1) when is_integer(boundary) and boundary > t0 and boundary <= t1 do
    if QuotaUsage.spans_previous_window?(series), do: boundary
  end

  defp window_boundary(_series, _t0, _t1), do: nil

  # The remainder sits behind the callers rather than shouting over them: it is
  # the largest band by far on a shared installation, and at full strength it
  # would swamp the rows an operator came to rank.
  defp band_opacity(%{kind: :outside}), do: "0.45"
  defp band_opacity(_band), do: "0.85"

  defp escape(text) do
    text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  @doc "How many caller slots the palette holds, for the stylesheet and tests."
  @spec palette_slots() :: pos_integer()
  def palette_slots, do: QuotaUsage.top_callers()

  # -- shared geometry ------------------------------------------------------

  defp domain(samples) do
    first = hd(samples).t_ms
    last = List.last(samples).t_ms
    if last > first, do: {first, last}, else: {first, first + 1}
  end

  defp stacked_areas(samples, layers, xf, yf) do
    zero = Map.new(samples, &{&1.t_ms, 0.0})

    {_cum, out} =
      Enum.reduce(layers, {zero, []}, fn {color, opacity, val}, {cum, acc} ->
        next = Map.new(samples, fn s -> {s.t_ms, Map.get(cum, s.t_ms) + val.(s)} end)
        top = Enum.map(samples, fn s -> {xf.(s.t_ms), yf.(Map.get(next, s.t_ms))} end)
        bot = samples |> Enum.map(fn s -> {xf.(s.t_ms), yf.(Map.get(cum, s.t_ms))} end) |> Enum.reverse()
        path = ~s|<path d="#{poly(top ++ bot)}" fill="#{color}" fill-opacity="#{opacity}" stroke="var(--surface)" stroke-width="0.4"/>|
        {next, [path | acc]}
      end)

    out |> Enum.reverse() |> Enum.join()
  end

  defp line([{x, y} | rest]) do
    "M #{r2(x)},#{r2(y)} " <> Enum.map_join(rest, " ", fn {a, b} -> "L #{r2(a)},#{r2(b)}" end)
  end

  defp line([]), do: ""

  defp poly([{x, y} | rest]) do
    "M #{r2(x)},#{r2(y)} " <> Enum.map_join(rest, " ", fn {a, b} -> "L #{r2(a)},#{r2(b)}" end) <> " Z"
  end

  defp poly([]), do: ""

  defp x_axis(t0, t1, xf, x0, x1, baseline) do
    ticks = for i <- 0..4, do: t0 + (t1 - t0) * i / 4

    base = ~s|<line x1="#{x0}" x2="#{x1}" y1="#{baseline}" y2="#{baseline}" stroke="var(--line)"/>|

    labels =
      Enum.map_join(ticks, "", fn t ->
        text(r2(xf.(t)), baseline + 14, fmt_elapsed(t - t0), anchor: "middle")
      end)

    base <> labels
  end

  defp y_grid(vmax, yf, x0, x1, fmt) do
    for i <- 0..3, into: "" do
      v = vmax * i / 3
      y = r2(yf.(v))

      ~s|<line x1="#{x0}" x2="#{x1}" y1="#{y}" y2="#{y}" stroke="var(--hairline)"/>| <>
        text(x0 - 6, y + 3, fmt.(v), anchor: "end")
    end
  end

  defp svg(h, inner, label) do
    ~s|<svg viewBox="0 0 #{@w} #{h}" role="img" aria-label="#{label}" preserveAspectRatio="xMidYMid meet" style="width:100%;height:auto;display:block">#{inner}</svg>|
  end

  defp text(x, y, body, opts) do
    anchor = Keyword.get(opts, :anchor, "start")
    ~s|<text x="#{x}" y="#{y}" text-anchor="#{anchor}" fill="var(--muted)" font-size="9" font-family="var(--an-mono, monospace)">#{body}</text>|
  end

  defp fmt_elapsed(ms) when ms <= 0, do: "0m"

  defp fmt_elapsed(ms) do
    total_min = div(round(ms / 1000), 60)
    h = div(total_min, 60)
    m = rem(total_min, 60)

    cond do
      h > 0 and m > 0 -> "#{h}h #{m}m"
      h > 0 -> "#{h}h"
      true -> "#{total_min}m"
    end
  end

  defp r2(v) when is_number(v), do: Float.round(v * 1.0, 2)
end

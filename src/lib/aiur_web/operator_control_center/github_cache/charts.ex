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

  The x axis is elapsed time since the first retained sample, so the charts say
  what they cover (the live-session ring) rather than pretending to be history
  the sampler never recorded.
  """

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

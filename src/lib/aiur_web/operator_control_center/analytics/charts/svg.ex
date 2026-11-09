defmodule AiurWeb.OperatorControlCenter.Analytics.Charts.Svg do
  @moduledoc false

  alias AiurWeb.OperatorControlCenter.Analytics.ChartAxis

  # ---- shared builders ----

  @spec stacked_areas([map()], [tuple()], function(), function()) :: String.t()
  def stacked_areas(series, layers, xf, yf) do
    zero = Map.new(series, &{&1.idx, 0.0})

    {_cum, out} =
      Enum.reduce(layers, {zero, []}, fn {color, op, vf}, {cum, acc} ->
        next = Map.new(series, fn s -> {s.idx, Map.get(cum, s.idx) + vf.(s)} end)
        top = Enum.map(series, fn s -> {xf.(s.t_ms), yf.(Map.get(next, s.idx))} end)
        bot = series |> Enum.map(fn s -> {xf.(s.t_ms), yf.(Map.get(cum, s.idx))} end) |> Enum.reverse()
        path = ~s|<path d="#{poly(top ++ bot)}" fill="#{color}" fill-opacity="#{op}" stroke="var(--surface)" stroke-width="0.4"/>|
        {next, [path | acc]}
      end)

    out |> Enum.reverse() |> Enum.join()
  end

  @spec poly([tuple()]) :: String.t()
  def poly([]), do: ""
  def poly(pts), do: line(pts) <> " Z"

  @spec line([tuple()]) :: String.t()
  def line([{x, y} | rest]) do
    "M #{r2(x)},#{r2(y)} " <> Enum.map_join(rest, " ", fn {a, b} -> "L #{r2(a)},#{r2(b)}" end)
  end

  def line([]), do: ""

  @spec area([tuple()], number()) :: String.t()
  def area(pts, base) do
    case pts do
      [] -> ""
      _ -> line(pts) <> " L #{r2(elem(List.last(pts), 0))},#{r2(base)} L #{r2(elem(hd(pts), 0))},#{r2(base)} Z"
    end
  end

  @spec step_line([tuple()]) :: String.t()
  def step_line([{x, y} | rest]) do
    {d, _} =
      Enum.reduce(rest, {"M #{r2(x)},#{r2(y)}", y}, fn {x2, y2}, {acc, py} ->
        {acc <> " L #{r2(x2)},#{r2(py)} L #{r2(x2)},#{r2(y2)}", y2}
      end)

    d
  end

  def step_line([]), do: ""

  @spec step_area([tuple()], number()) :: String.t()
  def step_area([], _base), do: ""

  def step_area(pts, base) do
    step_line(pts) <> " L #{r2(elem(List.last(pts), 0))},#{r2(base)} L #{r2(elem(hd(pts), 0))},#{r2(base)} Z"
  end

  @spec x_axis(number(), number(), function(), number(), number(), number(), number()) :: String.t()
  def x_axis(t0, t1, xf, x0, x1, baseline, origin_ms) do
    ticks = for i <- 0..4, do: t0 + (t1 - t0) * i / 4
    precision = if t1 - t0 < 300_000, do: :seconds, else: :minutes

    base = ~s|<line x1="#{x0}" x2="#{x1}" y1="#{baseline}" y2="#{baseline}" stroke="var(--line)"/>|

    labels =
      Enum.map_join(ticks, "", fn t ->
        text(r2(xf.(t)), baseline + 15, ChartAxis.elapsed(t - origin_ms, precision), anchor: "middle", fill: "var(--muted)")
      end)

    base <> labels
  end

  @spec y_grid([number()], function(), number(), number(), function()) :: String.t()
  def y_grid(ticks, yf, x0, x1, fmt) do
    Enum.map_join(ticks, "", fn v ->
      y = r2(yf.(v))

      ~s|<line x1="#{x0}" x2="#{x1}" y1="#{y}" y2="#{y}" stroke="var(--hairline)"/>| <>
        text(x0 - 6, y + 3, fmt.(v), anchor: "end", fill: "var(--muted)")
    end)
  end

  @spec svg(number(), number(), String.t(), String.t()) :: String.t()
  def svg(w, h, inner, label) do
    ~s|<svg viewBox="0 0 #{w} #{h}" role="img" aria-label="#{label}" preserveAspectRatio="xMidYMid meet" style="width:100%;height:auto;display:block;overflow:visible">#{inner}</svg>|
  end

  @spec time_svg(number(), number(), String.t(), String.t(), tuple()) :: String.t()
  def time_svg(w, h, inner, label, {t0, t1, x0, x1, y0, y1}) do
    brush =
      ~s|<rect class="an-time-brush-target" data-time-brush="true" x="#{x0}" y="#{y0}" width="#{x1 - x0}" height="#{y1 - y0}" fill="transparent" style="cursor:crosshair;touch-action:none"/>|

    ~s|<svg viewBox="0 0 #{w} #{h}" role="img" aria-label="#{label}" data-time-brush="true" data-time-start="#{round(t0)}" data-time-end="#{round(t1)}" preserveAspectRatio="xMidYMid meet" style="width:100%;height:auto;display:block;overflow:visible">#{inner}#{brush}</svg>|
  end

  @spec now_marker(number(), number(), number(), function(), number(), number()) :: String.t()
  def now_marker(t0, t1, now_ms, xf, y0, y1) when now_ms >= t0 and now_ms <= t1 do
    x = r2(xf.(now_ms))

    ~s|<line class="an-now-marker" x1="#{x}" x2="#{x}" y1="#{y0}" y2="#{y1}" stroke="var(--attention)" stroke-width="1"/><text x="#{x}" y="#{y0 + 9}" text-anchor="middle" fill="var(--attention)" font-size="9" font-family="var(--an-mono, monospace)">now</text>|
  end

  def now_marker(_t0, _t1, _now_ms, _xf, _y0, _y1), do: ""

  @spec text(number(), number(), term(), keyword()) :: String.t()
  def text(x, y, body, opts) do
    anchor = Keyword.get(opts, :anchor, "start")
    fill = Keyword.get(opts, :fill, "var(--muted)")
    ~s|<text x="#{x}" y="#{y}" text-anchor="#{anchor}" fill="#{fill}" font-size="9" font-family="var(--an-mono, monospace)">#{escape_text(body)}</text>|
  end

  @spec title(term()) :: String.t()
  def title(body), do: "<title>#{escape_text(body)}</title>"

  defp escape_text(body),
    do: body |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # ---- formatting / palette ----

  @spec scolor(integer()) :: String.t()
  def scolor(i), do: "var(--an-s#{rem(i - 1, 8) + 1})"

  @spec fmt_bytes(term()) :: String.t()
  def fmt_bytes(b) when is_number(b) do
    cond do
      b >= 1_073_741_824 -> "#{Float.round(b / 1_073_741_824, 1)} GB"
      b >= 1_048_576 -> "#{round(b / 1_048_576)} MB"
      b >= 1024 -> "#{round(b / 1024)} KB"
      true -> "#{round(b)} B"
    end
  end

  def fmt_bytes(_b), do: "0 B"

  @spec r2(number()) :: float()
  def r2(v) when is_number(v), do: Float.round(v * 1.0, 2)
end

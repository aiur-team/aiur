defmodule AiurWeb.Experiments.Charts.Distribution do
  @moduledoc false
  alias AiurWeb.Experiments.Charts.Svg

  @spec render(map()) :: String.t()
  def render(metric) do
    values = for group <- metric.groups, value <- [group.median, group.q1, group.q3] ++ Tuple.to_list(group.whiskers || {}) ++ Enum.map(group.points, & &1["value"]), is_number(value), do: value
    domain = Svg.domain(values, metric.scale)
    groups = Enum.with_index(metric.groups) |> Enum.map(fn {group, index} -> group(group, index, length(metric.groups), domain, metric) end)

    ticks =
      Enum.map(Svg.ticks(domain, metric.scale), fn value ->
        y = position(value, domain, metric.scale)
        [Svg.line(60, y, 610, y, "exp-grid"), Svg.text(0, y, Svg.number(value))]
      end)

    rows = for group <- metric.groups, point <- group.points, do: [group.label, point["unit_id"], Svg.number(point["value"])]
    summary = for group <- metric.groups, do: [group.label, Svg.number(group.n), Svg.number(group.median), Svg.number(group.q1), Svg.number(group.q3), range(group.whiskers)]
    label = "#{metric.label} distribution in #{metric.unit}, #{metric.scale} scale; #{length(rows)} samples shown."
    Svg.wrap(label, 300, [ticks, groups]) <> Svg.table("Group distributions", ~w(Group N Median Q1 Q3 Whiskers), summary) <> Svg.table("Distribution samples", ~w(Group Sample Value), rows)
  end

  defp group(group, index, count, domain, metric) do
    scale = metric.scale
    class = if metric.cohorts?, do: "exp-point", else: "exp-point exp-#{group.name}"
    x = 95 + (index + 0.5) * 480 / max(count, 1)
    points = group.points |> Enum.with_index() |> Enum.filter(fn {point, _} -> valid?(point["value"], scale) end)
    dots = Enum.map(points, fn {point, sample} -> Svg.marker(x + jitter(sample), position(point["value"], domain, scale), index, class) end)
    count = if is_integer(group.n), do: "n #{group.n}", else: "sample count unavailable"
    [box(group, x, domain, scale), dots, Svg.text(x - 30, 275, group.label), Svg.text(x - 30, 292, "#{count}, showing #{length(points)}")]
  end

  defp box(group, x, domain, scale) do
    if Enum.all?([group.q1, group.q3, group.median], &valid?(&1, scale)) do
      y1 = position(group.q3, domain, scale)
      y2 = position(group.q1, domain, scale)
      box = if is_integer(group.n) and group.n > 1, do: Svg.rect(x - 22, y1, 44, y2 - y1, "exp-box"), else: ""
      [whisker(group.whiskers, x, domain, scale), box, Svg.line(x - 22, position(group.median, domain, scale), x + 22, position(group.median, domain, scale), "exp-median")]
    else
      ""
    end
  end

  defp whisker({lo, hi}, x, domain, scale), do: Svg.line(x, position(lo, domain, scale), x, position(hi, domain, scale), "exp-whisker")
  defp whisker(nil, _x, _domain, _scale), do: ""
  defp range({lo, hi}), do: "#{Svg.number(lo)} to #{Svg.number(hi)}"
  defp range(nil), do: "Unavailable"
  defp valid?(value, "log"), do: is_number(value) and value > 0
  defp valid?(value, _), do: is_number(value)
  defp position(value, domain, scale), do: Svg.position(value, domain, {240, 20}, scale)
  defp jitter(index), do: rem(index * 37 + 11, 31) - 15
end

defmodule AiurWeb.Experiments.Charts.Forest do
  @moduledoc false
  alias AiurWeb.Experiments.Charts.Svg

  @spec render([map()]) :: String.t()
  def render(metrics) do
    values = for metric <- metrics, not metric.guarded?, value <- Map.values(metric.effect), is_number(value), do: value
    extent = Enum.max(Enum.map(values, &abs/1), fn -> 50 end) |> max(1)
    domain = {-extent, extent}
    body = Enum.with_index(metrics) |> Enum.map(fn {metric, index} -> row(metric, 35 + index * 85, domain) end)
    height = length(metrics) * 85 + 35
    axis = [Svg.line(340, 10, 340, height - 20, "exp-zero"), Svg.text(330, height - 4, "0%"), Svg.text(100, height - 4, "#{Svg.number(-extent)}%"), Svg.text(555, height - 4, "#{Svg.number(extent)}%")]
    table = Svg.table("Median changes and confidence intervals", ~w(Metric Estimate Low High Evidence), Enum.map(metrics, &table_row/1))
    Svg.wrap("Median changes in percent with confidence intervals; hollow points mean not enough data or unavailable estimates.", height, [body, axis]) <> table
  end

  defp row(metric, y, domain) do
    lower? = metric.expected in ~w(decrease lower_is_better)
    x = if lower?, do: 100, else: 340
    estimate = if metric.guarded?, do: nil, else: metric.effect.estimate
    dot = Svg.marker(position(estimate || 0, domain), y + 30, 0, if(is_nil(estimate), do: "exp-hollow", else: "exp-estimate"))
    bar = interval(metric, y + 30, domain)
    status = if metric.guarded?, do: "not enough data", else: if(is_nil(estimate), do: "Percent change unavailable", else: "#{Svg.number(estimate)}%")
    [expected(metric, x, y), Svg.text(10, y, metric.label), bar, dot, Svg.text(100, y + 70, status)]
  end

  defp expected(%{expected: direction}, x, y) when direction in ~w(decrease increase lower_is_better higher_is_better),
    do: [Svg.rect(x, y + 8, 240, 44, "exp-expected"), Svg.text(x + 6, y + 22, "expected")]

  defp expected(_metric, _x, _y), do: ""

  defp interval(%{guarded?: false, effect: %{lo: lo, hi: hi}}, y, domain) when is_number(lo) and is_number(hi),
    do: Svg.line(position(lo, domain), y, position(hi, domain), y, "exp-ci")

  defp interval(_metric, _y, _domain), do: ""
  defp position(value, domain), do: Svg.position(value, domain, {100, 580})

  defp table_row(metric) do
    numbers = if metric.guarded?, do: List.duplicate("not enough data", 3), else: Enum.map([metric.effect.estimate, metric.effect.lo, metric.effect.hi], &Svg.number/1)
    [metric.label] ++ numbers ++ [if(metric.guarded?, do: "not enough data", else: "Stored evidence")]
  end
end

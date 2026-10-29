defmodule AiurWeb.Experiments.Charts.Power do
  @moduledoc false
  alias AiurWeb.Experiments.Charts.Svg

  @spec render([map()], map()) :: String.t()
  def render(metrics, detail) do
    rows = for metric <- metrics, group <- metric.groups, do: row(metric, group, detail)
    body = Enum.map_join(rows, &bar/1)
    table = Svg.table("Sample requirements and power", ["Metric", "Group", "Now", "Needed", "MDE", "Power", "Evidence"], Enum.map(rows, & &1.data))
    body <> table
  end

  defp row(metric, group, detail) do
    needed = group.needed
    minimum? = not is_integer(needed)
    target = if minimum?, do: metric.minimum, else: max(needed, metric.minimum)
    text = sample_text(metric, group, target, minimum?, detail)
    count = if is_integer(group.n), do: "n #{group.n} of #{target} needed", else: "target #{target} needed"

    %{
      n: group.n,
      target: target,
      text: "#{metric.label} · #{group.label}: #{count}; #{text}",
      data: [metric.label, group.label, Svg.number(group.n), target, Svg.number(metric.power["mde_at_current_n"]), Svg.number(metric.power["power_at_current_n"]), text]
    }
  end

  defp sample_text(_metric, %{n: nil}, _target, _minimum?, _detail), do: "sample count unavailable"

  defp sample_text(metric, group, target, minimum?, detail) do
    remaining = max(target - group.n, 0)
    text = if remaining > 0, do: "needs #{remaining} more #{suffix(detail.design, group)}", else: "Sample minimum reached"
    evidence_text(text, minimum?, metric, remaining)
  end

  defp suffix(%{"kind" => "before_after"}, %{name: "before"}), do: "before the line"
  defp suffix(%{"kind" => "before_after"}, %{name: "after"}), do: "after the line"
  defp suffix(_design, group), do: "in cohort #{group.label}"

  defp evidence_text(text, true, metric, _remaining), do: text <> "; power requirement #{metric.power["samples_needed_per_group"] || "unavailable"}"
  defp evidence_text(text, false, _metric, remaining) when remaining > 0, do: text

  defp evidence_text(_text, false, %{mde: mde, power_target: power}, _remaining) when is_number(mde) and is_number(power),
    do: "enough samples for a #{Svg.number(mde * 100)}% effect at #{Svg.number(power * 100)}% power"

  defp evidence_text(_text, false, _metric, _remaining), do: "Power sample target reached; target effect size or power unavailable"

  defp bar(row) do
    fill = if is_integer(row.n), do: Svg.rect(10, 5, 580 * min(row.n / max(row.target, 1), 1), 12, "exp-meter-fill"), else: ""
    bars = [Svg.rect(10, 5, 580, 12, "exp-meter-track"), fill]
    "<p>" <> Svg.escape(row.text) <> "</p>" <> Svg.wrap(row.text, 25, bars)
  end
end

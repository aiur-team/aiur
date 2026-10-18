defmodule Aiur.Experiments.ChartData do
  @moduledoc "Projects stored experiment evidence for charts without rerunning inference."
  alias Aiur.Experiments.ChartGroups

  @spec attach({:ok, map()} | {:error, term()}, keyword()) :: {:ok, map()} | {:error, term()}
  def attach({:ok, detail}, opts) do
    analysis = Map.get(detail, :analysis) || %{}
    strata = strata(analysis)
    field = Enum.join(detail.spec["stratify_by"] || [], "×")
    selected = Keyword.get(opts, :stratum)
    selected = if is_binary(selected), do: String.replace_prefix(selected, field <> ":", "")
    selected = if selected in strata, do: selected
    metrics = Map.get(analysis, "metrics", %{})
    specs = Map.get(detail, :chart_metric_specs, detail.spec["metrics"] || [])
    charts = Enum.map(specs, &metric(&1, metrics[&1["ref"]], analysis, detail, selected))
    {:ok, Map.merge(detail, %{chart_metrics: charts, strata: Enum.map(strata, &(field <> ":" <> &1)), stratum: if(selected, do: field <> ":" <> selected)})}
  end

  def attach(error, _opts), do: error

  defp strata(analysis) do
    analysis |> Map.get("metrics", %{}) |> Map.values() |> Enum.flat_map(&(Map.get(&1, "strata", %{}) |> Map.keys())) |> Enum.uniq() |> Enum.sort()
  end

  defp metric(spec, result, analysis, detail, selected) do
    result = result || %{}
    result = if selected, do: get_in(result, ["strata", selected]) || %{}, else: result
    minimum = spec["min_samples"] || get_in(analysis, ["defaults", "min_samples"]) || detail.spec["min_samples"]
    groups = ChartGroups.build(detail, spec["ref"], result, Map.get(analysis, "group_order", []), selected)

    %{
      ref: spec["ref"],
      cohorts?: detail.spec["design"]["kind"] == "ab",
      expected: spec["direction"],
      scale: scale(result, groups),
      groups: Enum.map(groups, &Map.put(&1, :needed, samples_needed(&1.name, result))),
      guarded?: result["status"] == "insufficient_data" or Enum.any?(groups, &(not is_integer(&1.n) or &1.n < minimum)),
      effect: percent(get_in(result, ["effects", "median_ratio"])),
      power: Map.get(result, "power", %{}),
      minimum: minimum,
      mde: spec["mde"],
      power_target: get_in(analysis, ["defaults", "power_target"]),
      rolling: Map.get(result, "rolling_median", [])
    }
  end

  defp samples_needed(name, result) do
    power = Map.get(result, "power", %{})
    needed = power["samples_needed_per_group"]
    ratio = power["allocation_ratio"]
    if is_integer(needed) and is_number(ratio) and name != power["baseline_group"], do: ceil(needed * ratio), else: needed
  end

  defp scale(result, groups) do
    values = for group <- groups, value <- [group.median, group.q1, group.q3] ++ Tuple.to_list(group.whiskers || {}) ++ Enum.map(group.points, & &1["value"]), is_number(value), do: value
    positive? = values != [] and Enum.all?(values, &(&1 > 0))
    log? = result["scale"] == "log" or (result["kind"] == "duration" and positive? and Enum.max(values) / Enum.min(values) >= 100)
    if log? and positive?, do: "log", else: "linear"
  end

  defp percent(effect) when is_map(effect), do: Map.new(~w(estimate lo hi)a, &{&1, percent_value(effect[Atom.to_string(&1)])})
  defp percent(_), do: %{estimate: nil, lo: nil, hi: nil}
  defp percent_value(value) when is_number(value), do: (value - 1) * 100
  defp percent_value(_), do: nil
end

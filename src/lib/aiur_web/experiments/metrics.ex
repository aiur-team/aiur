defmodule AiurWeb.Experiments.Metrics do
  @moduledoc "Formats stored analysis output without running statistical analysis."

  @spec rows(map(), map() | nil, map()) :: [map()]
  def rows(spec, %{"metrics" => results, "group_order" => order} = analysis, catalog) do
    minimum = get_in(analysis, ["defaults", "min_samples"]) || spec["min_samples"]
    for metric <- Map.get(spec, "metrics", []), result = results[metric["ref"]], is_map(result), do: row(metric, result, order, minimum, catalog)
  end

  def rows(_spec, _analysis, _catalog), do: []

  defp row(metric, result, order, minimum, catalog) do
    definition = catalog[metric["ref"]] || %{}
    groups = Enum.map(order, &group(&1, result["groups"][&1], result["kind"]))
    count = groups |> Enum.map(& &1.n) |> Enum.min()
    guarded? = result["status"] == "insufficient_data"

    base = %{
      label: Map.get(definition, :label, metric["ref"]),
      unit: Map.get(definition, :unit, "Unknown unit"),
      groups: groups,
      sample: "n #{count}/#{minimum}",
      guarded?: guarded?,
      change: change(result),
      direction: if(guarded?, do: "Direction unavailable", else: direction(result["direction"])),
      tests: result |> Map.get("tests", %{}) |> Map.keys() |> Enum.sort() |> Enum.join(", "),
      labels: Enum.map(Map.get(result, "analyst_flags", []), &"analyst: #{&1["flag"]} — #{&1["reason"]}")
    }

    Map.merge(base, inference(result, count, minimum))
  end

  defp inference(%{"status" => "insufficient_data"}, count, minimum) do
    guard = "not enough data (n #{count} of #{minimum})"
    %{contrast: guard, interval: guard, effect: guard, p: guard}
  end

  defp inference(result, _count, _minimum) do
    effect = get_in(result, ["effects", result["primary_effect"]]) || %{}
    name = if get_in(result, ["effects", "median_difference"]), do: "median_difference", else: result["primary_effect"]
    contrast = get_in(result, ["effects", name]) || %{}

    %{
      contrast: "#{name}: #{number(contrast["estimate"])}",
      interval: "#{number(contrast["lo"])} to #{number(contrast["hi"])}",
      effect: "#{result["primary_effect"]}: #{number(effect["estimate"])}",
      p: "#{number(result["p_raw"])} (#{result["adjustment"]}: #{number(result["p_adj"])})"
    }
  end

  defp group(name, values, "rate"), do: %{name: name, n: values["n"], center_label: "rate", center: number(values["rate"]), spread: "Not applicable"}
  defp group(name, values, _kind), do: %{name: name, n: values["n"], center_label: "median", center: number(values["median"]), spread: "#{number(values["q1"])} to #{number(values["q3"])}"}
  defp change(%{"effects" => %{"median_ratio" => %{"estimate" => ratio}}}) when is_number(ratio), do: signed((ratio - 1) * 100) <> "%"
  defp change(_result), do: "Change unavailable"
  defp signed(value) when value > 0, do: "+" <> number(value)
  defp signed(value), do: number(value)
  defp number(value) when is_number(value) and value != 0 and abs(value) < 0.01, do: :erlang.float_to_binary(value / 1, scientific: 2)
  defp number(value) when is_number(value), do: :erlang.float_to_binary(value / 1, decimals: 2) |> String.trim_trailing("0") |> String.trim_trailing(".")
  defp number(_value), do: "Unavailable"
  defp direction("improved"), do: "✓ in expected direction"
  defp direction("regressed"), do: "↗ against expected direction"
  defp direction("no_change"), do: "↔ no clear direction"
  defp direction(_direction), do: "Direction unavailable"
end

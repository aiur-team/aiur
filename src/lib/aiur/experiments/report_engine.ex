defmodule Aiur.Experiments.ReportEngine do
  @moduledoc false
  alias Aiur.Experiments.Evidence

  @labels %{
    "insufficient_data" => "not-enough-data",
    "underpowered" => "underpowered",
    "inconclusive" => "inconclusive",
    "practically_equivalent" => "no-effect-detected",
    "significant" => "significant"
  }

  @spec spec(map(), map(), map()) :: map()
  def spec(input, registration, catalog) do
    metrics =
      Enum.map(input["spec"]["metrics"], fn metric ->
        definition = Map.fetch!(catalog.metrics, metric["ref"])
        Map.merge(metric, %{"id" => metric["ref"], "kind" => definition.kind, "mde" => mde(metric, registration), "direction" => expected_direction(metric, registration)})
      end)

    Map.merge(input["spec"], %{
      "metrics" => metrics,
      "primary_metrics" => Enum.map(registration["primary_metrics"], & &1["id"]),
      "alpha" => registration["alpha"],
      "fdr_q" => registration["fdr_q"],
      "power_target" => registration["power_target"]
    })
  end

  @spec context(map(), map(), map(), map()) :: map()
  def context(body, registration, events, catalog) do
    rows = Map.new(body["metrics"], fn {id, metric} -> {id, row(id, metric, registration, catalog)} end)

    %{
      experiment_id: body["experiment_id"],
      stats_snapshot_hash: Evidence.hash(body),
      preregistration: registration,
      events: events,
      engine_results: rows,
      engine_labels: Map.new(rows, fn {id, row} -> {id, row["engine_label"]} end)
    }
  end

  defp row(id, metric, registration, catalog) do
    effect_kind = metric["primary_effect"] || "median_difference"
    effect = get_in(metric, ["effects", effect_kind]) || %{}
    label = Map.fetch!(@labels, metric["status"])
    needed = get_in(metric, ["power", "samples_needed_per_group"])

    %{
      "metric" => id,
      "role" => role(id, registration),
      "unit" => Map.fetch!(catalog.metrics, id).unit,
      "n" => groups(metric, "n"),
      "median" => groups(metric, "median"),
      "iqr" => quartiles(metric),
      "effect" => %{"kind" => effect_kind, "value" => effect["estimate"]},
      "ci95" => interval(effect),
      "p" => metric["p_raw"],
      "p_adjusted" => metric["p_adj"],
      "family" => metric["adjustment"],
      "power_at_mde" => get_in(metric, ["power", "power_at_current_n"]),
      "mde_at_n" => get_in(metric, ["power", "mde_at_current_n"]),
      "n_needed_per_cohort" => if(is_integer(needed), do: needed),
      "engine_label" => label,
      "label" => label,
      "label_reason" => "",
      "modifiers" => [],
      "direction" => direction(metric["direction"])
    }
  end

  defp expected_direction(metric, registration) do
    registered = Enum.flat_map(~w(primary_metrics secondary_metrics guardrail_metrics), &registration[&1])

    case Enum.find(registered, &(&1["id"] == metric["ref"])) do
      nil -> metric["direction"]
      row -> Map.fetch!(%{"decrease" => "decrease", "no-increase" => "decrease", "increase" => "increase", "no-decrease" => "increase", "no-change" => "none"}, row["expected"])
    end
  end

  defp mde(metric, registration) do
    if metric["ref"] == registration["mde"]["metric"], do: abs(registration["mde"]["relative"]), else: metric["mde"] || 0.2
  end

  defp groups(metric, key), do: Map.new(metric["groups"], fn {group, values} -> {group, values[key]} end)
  defp quartiles(metric), do: Map.new(metric["groups"], fn {group, values} -> {group, if(is_number(values["q1"]) and is_number(values["q3"]), do: [values["q1"], values["q3"]], else: nil)} end)
  defp interval(%{"lo" => lo, "hi" => hi}) when is_number(lo) and is_number(hi), do: [lo, hi]
  defp interval(_effect), do: nil
  defp direction("improved"), do: "as-expected"
  defp direction("regressed"), do: "opposite"
  defp direction(_none), do: "none"

  defp role(id, registration) do
    Enum.find_value([{"primary_metrics", "primary"}, {"secondary_metrics", "secondary"}, {"guardrail_metrics", "guardrail"}], "exploratory", fn {field, role} ->
      if Enum.any?(registration[field], &(&1["id"] == id)), do: role
    end)
  end
end

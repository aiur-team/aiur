defmodule Aiur.Experiments.ReportContract do
  @moduledoc "Pure report validation against server-owned frozen evidence."
  alias Aiur.Experiments.{ContractSchema, Evidence}

  @computed ~w(unit direction n median iqr effect ci95 p p_adjusted family power_at_mde mde_at_n n_needed_per_cohort)
  @labels ~w(not-enough-data underpowered inconclusive no-effect-detected significant)

  @spec validate(map(), map()) :: {:ok, map(), [String.t()]} | {:error, [map()]}
  def validate(report, context) do
    with :ok <- ContractSchema.validate(report, "report") do
      errors = identity(report, context) ++ results(report, context) ++ ledger(report, context) ++ summary(report["summary"]) ++ labels(report)
      if errors == [], do: analysis_type(report, context.preregistration), else: {:error, errors}
    end
  end

  defp identity(report, context) do
    header = report["header"]

    checks = [
      {header["experiment_id"] == context.experiment_id, "header.experiment_id", "does not match experiment"},
      {header["stats_snapshot_hash"] == context.stats_snapshot_hash, "header.stats_snapshot_hash", "stale stats snapshot hash"},
      {header["events_snapshot_hash"] == context.events["snapshot_hash"], "header.events_snapshot_hash", "stale events snapshot hash"},
      {header["preregistration_hash"] == Evidence.hash(context.preregistration), "header.preregistration_hash", "stale preregistration hash"},
      {report["preregistration"]["record"] == context.preregistration, "preregistration.record", "must match stored preregistration"}
    ]

    Enum.flat_map(checks, fn {ok?, path, message} -> if ok?, do: [], else: error(path, message) end)
  end

  defp results(report, context) do
    rows = report["results"]
    ids = Enum.map(rows, & &1["metric"])
    expected = Map.keys(context.engine_labels)
    membership = if Enum.sort(ids) == Enum.sort(expected), do: [], else: error("results", "must include every engine metric exactly once")
    membership ++ Enum.flat_map(rows, &metric(&1, context))
  end

  defp metric(row, context) do
    path = "results." <> row["metric"]
    engine = Map.get(context.engine_labels, row["metric"])
    primary? = Enum.any?(context.preregistration["primary_metrics"], &(&1["id"] == row["metric"]))

    cond do
      row["engine_label"] != engine -> error(path, "engine_label does not match recomputed engine")
      rank(row["label"]) > rank(engine) -> error(path, "label upgrades are forbidden")
      rank(row["label"]) < rank(engine) and String.trim(row["label_reason"]) == "" -> error(path, "downgrade needs label_reason")
      primary? != (row["role"] == "primary") -> error(path, "primary role must match preregistration")
      row["role"] != context.engine_results[row["metric"]]["role"] -> error(path, "metric role must match preregistration")
      Map.take(row, @computed) != Map.take(context.engine_results[row["metric"]], @computed) -> error(path, "numbers must match recomputed engine")
      true -> []
    end
  end

  defp ledger(report, context) do
    ids = Enum.map(report["confounders"], & &1["event_id"])
    expected = Enum.map(context.events["events"], & &1["event_id"])
    missing = if Enum.sort(ids) == Enum.sort(expected), do: [], else: error("confounders", "must review every event id exactly once")
    missing ++ Enum.flat_map(report["confounders"], &confounder(&1, report))
  end

  defp confounder(event, report) do
    sensitivity_ids = Enum.map(report["sensitivity"], & &1["id"])
    unknown = event["affects"] -- Enum.map(report["results"], & &1["metric"])

    cond do
      unknown != [] -> error("confounders", "affects contains unknown metrics")
      event["handling"] == "sensitivity" and event["sensitivity_id"] not in sensitivity_ids -> error("confounders", "sensitivity handling needs a matching sensitivity_id")
      event["severity"] == "high" and event["handling"] == "noted" -> require_confounded(event, report)
      true -> []
    end
  end

  defp require_confounded(event, report) do
    report["results"]
    |> Enum.filter(&(&1["metric"] in event["affects"] and "confounded" not in &1["modifiers"]))
    |> Enum.flat_map(&error("results." <> &1["metric"], "high/noted confounder requires confounded"))
  end

  defp summary(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+|\n+/u, trim: true)
    |> Enum.flat_map(fn sentence ->
      verdict? = Regex.match?(~r/\b(not-enough-data|underpowered|inconclusive|no-effect-detected|significant|confounded)\b/i, sentence)
      if verdict? and not Regex.match?(~r/\d/, sentence), do: error("summary", "bare label word needs a number in the same sentence"), else: []
    end)
  end

  defp labels(report) do
    expected = report["results"] |> Enum.filter(&(&1["role"] == "primary")) |> Enum.flat_map(&[&1["label"] | &1["modifiers"]]) |> Enum.uniq() |> Enum.sort()
    if Enum.sort(report["labels"]) == expected, do: [], else: error("labels", "must derive from primary metric labels and modifiers")
  end

  defp analysis_type(report, registration) do
    primary = Enum.filter(report["results"], &(&1["role"] == "primary"))
    below? = Enum.any?(primary, fn row -> Enum.any?(row["n"], fn {_cohort, n} -> n < registration["planned_n_per_cohort"] end) end)

    if report["header"]["analysis_type"] == "confirmatory" and below? do
      {:ok, put_in(report, ["header", "analysis_type"], "interim"), ["confirmatory rewritten to interim: below planned n"]}
    else
      {:ok, report, []}
    end
  end

  defp rank(label), do: Enum.find_index(@labels, &(&1 == label))
  defp error(path, message), do: [%{path: path, message: message}]
end

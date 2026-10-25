defmodule Aiur.Experiments.Arms do
  @moduledoc "Assigns per-unit window evidence to experiment arms."

  alias Aiur.Experiments.{Predicate, Reader, WindowData}

  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(id, opts \\ []) do
    with {:ok, spec, false} <- Reader.spec(id),
         {:ok, windows} <- windows(spec, Keyword.get(opts, :context, %{})) do
      {:ok, assign(spec, windows)}
    else
      {:ok, _spec, true} -> {:error, :newer_spec}
      error -> error
    end
  end

  defp windows(spec, ctx) do
    spec["windows"]
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case WindowData.read(spec, name, ctx) do
        {:ok, data} -> {:cont, {:ok, [{name, data} | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  @spec assign(map(), [{String.t(), map()}]) :: map()
  def assign(spec, windows) do
    groups = if spec["design"]["kind"] == "ab", do: Enum.map(spec["design"]["cohorts"], & &1["id"]), else: ~w(before after)
    metrics = Map.new(spec["metrics"], &{&1["ref"], %{"n" => 0, "observations" => [], "coverage" => %{}}})
    arms = Map.new(groups, &{&1, %{"source" => nil, "metrics" => metrics}})
    initial = %{"experiment_id" => spec["id"], "arms" => arms, "excluded" => Map.new(~w(straddle ambiguous filtered), &{&1, MapSet.new()})}

    covered = Enum.reduce(windows, initial, fn {window, data}, acc -> cover_window(spec, window, data, acc) end)

    rows =
      for {_window, data} <- windows, {ref, metric} <- data.metrics, row <- metric["observations"] do
        source = get_in(Map.get(data, :row_sources, %{}), [ref, row["unit_id"]]) || data.source
        {ref, row, to_string(source)}
      end

    rows
    |> Enum.sort_by(fn {ref, row, source} -> {source_priority(source), ref, row["unit_id"], row["at"]} end)
    |> Enum.uniq_by(fn {ref, row, _source} -> {ref, row["unit_id"]} end)
    |> Enum.reduce(covered, fn {ref, row, source}, acc -> assign_row(spec, ref, row, source, acc) end)
    |> sort_rows()
  end

  defp cover_window(spec, window, data, result) do
    source = to_string(data.source)
    groups = if spec["design"]["kind"] == "ab", do: Map.keys(result["arms"]), else: [window]

    Enum.reduce(data.metrics, result, fn {ref, metric}, acc ->
      Enum.reduce(groups, acc, &put_coverage(&2, &1, ref, metric["coverage"], source))
    end)
  end

  defp put_coverage(result, group, ref, coverage, source) do
    result
    |> put_in(["arms", group, "metrics", ref, "coverage"], coverage)
    |> update_in(["arms", group, "source"], &merge_source(&1, source))
  end

  defp assign_row(spec, ref, row, source, result) do
    case group(spec, row) do
      {:excluded, reason} ->
        update_in(result, ["excluded", reason], &MapSet.put(&1, row["unit_id"]))

      {:arm, group} ->
        result
        |> update_in(["arms", group, "metrics", ref, "observations"], &[row | &1])
        |> update_in(["arms", group, "metrics", ref, "n"], &(&1 + 1))
        |> update_in(["arms", group, "source"], &merge_source(&1, source))
    end
  end

  defp source_priority("frozen"), do: 0
  defp source_priority("checkpoint"), do: 2
  defp source_priority("mixed"), do: 1
  defp source_priority("live"), do: 3

  defp merge_source(nil, source), do: source
  defp merge_source(source, source), do: source
  defp merge_source(_previous, _source), do: "mixed"

  defp group(spec, row) do
    attrs = row["attrs"] || %{}

    if Predicate.matches?(spec["filters"], attrs) do
      design_group(spec, row, attrs)
    else
      {:excluded, "filtered"}
    end
  end

  defp design_group(%{"design" => %{"kind" => "ab", "cohorts" => cohorts}}, _row, attrs) do
    case Enum.filter(cohorts, &Predicate.matches?(&1["where"], attrs)) do
      [cohort] -> {:arm, cohort["id"]}
      [] -> {:excluded, "filtered"}
      _many -> {:excluded, "ambiguous"}
    end
  end

  defp design_group(spec, row, _attrs) do
    change = timestamp(spec["design"]["change"]["time"])
    after_start = timestamp(spec["windows"]["after"]["start"])
    finish = timestamp(row["finished_at"])
    at = assignment_time(spec["design"], row, finish)

    cond do
      is_nil(at) -> {:excluded, "straddle"}
      DateTime.compare(at, change) == :lt and before_finished?(row, finish, change) -> {:arm, "before"}
      DateTime.compare(at, after_start) != :lt -> {:arm, "after"}
      true -> {:excluded, "straddle"}
    end
  end

  defp assignment_time(%{"assign_by" => "finish"}, row, finish), do: finish || started_at(row)
  defp assignment_time(_design, row, _finish), do: started_at(row)
  defp started_at(row), do: timestamp(row["started_at"] || row["at"])

  defp before_finished?(_row, nil, _change), do: true
  defp before_finished?(_row, finish, change), do: DateTime.compare(finish, change) != :gt

  defp timestamp(nil), do: nil

  defp timestamp(at) do
    {:ok, parsed, _offset} = DateTime.from_iso8601(at)
    parsed
  end

  defp sort_rows(result) do
    result = update_in(result, ["excluded"], &Map.new(&1, fn {reason, units} -> {reason, MapSet.size(units)} end))

    update_in(result, ["arms"], fn arms ->
      Map.new(arms, fn {group, arm} -> {group, Map.update!(arm, "metrics", &sort_metrics/1)} end)
    end)
  end

  defp sort_metrics(metrics) do
    Map.new(metrics, fn {ref, metric} ->
      rows = Enum.sort_by(metric["observations"], &{&1["unit_id"], &1["at"]})
      {ref, Map.put(metric, "observations", rows)}
    end)
  end
end

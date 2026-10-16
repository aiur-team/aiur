defmodule AiurWeb.Experiments.ViewModel do
  @moduledoc "Experiment metadata formatted for display, without computing statistical evidence."

  alias AiurWeb.Experiments.Metrics

  @spec index_item(map(), map(), map()) :: map()
  def index_item(summary, detail, catalog \\ %{}) do
    spec = Map.get(detail, :spec, %{})
    metrics = Metrics.rows(spec, Map.get(detail, :analysis), catalog)

    %{
      id: summary.id,
      title: Map.get(summary, :title) || summary.id,
      kind_label: kind_label(Map.get(spec, "design")),
      status: Map.get(summary, :status) || "unknown",
      phase: Map.get(detail, :phase, :unknown),
      created_at: Map.get(summary, :created_at),
      metrics: metrics,
      labels: metrics |> Enum.flat_map(& &1.labels) |> Enum.uniq(),
      evidence_state: if(is_map(Map.get(detail, :analysis)), do: :available, else: :pending)
    }
  end

  @spec detail(map(), map()) :: map()
  def detail(detail, catalog \\ %{}) do
    spec = Map.get(detail, :spec, %{})
    summary = Map.new(~w(id title status created_at)a, &{&1, Map.get(spec, Atom.to_string(&1))})

    Map.merge(index_item(summary, detail, catalog), %{
      hypothesis: Map.get(spec, "hypothesis", ""),
      design: Map.get(spec, "design"),
      windows: Map.get(spec, "windows", %{}),
      window_labels: window_labels(Map.get(spec, "windows", %{})),
      design_summary: design_summary(Map.get(spec, "design")),
      metric_specs: Enum.map(Map.get(spec, "metrics", []), &metric_spec(&1, catalog)),
      min_samples: Map.get(spec, "min_samples"),
      frozen_baseline: frozen_baseline(spec, Map.get(detail, :snapshots, [])),
      pack_changed_since_freeze?: Map.get(detail, :pack_changed_since_freeze, false),
      annotations: Map.get(detail, :annotations, []),
      read_only?: Map.get(detail, :read_only?, false)
    })
  end

  defp frozen_baseline(%{"design" => %{"kind" => "before_after"}}, snapshots) do
    snapshots
    |> Enum.filter(&match?(%{"window_name" => "before", "revision" => revision} when is_integer(revision), &1))
    |> Enum.max_by(& &1["revision"], fn -> nil end)
    |> baseline_metadata()
  end

  defp frozen_baseline(_spec, _snapshots), do: :unknown
  defp baseline_metadata(nil), do: :unknown

  defp baseline_metadata(snapshot),
    do: Map.new(~w(revision computed_at aiur_version sha256)a, &{&1, snapshot[Atom.to_string(&1)]})

  defp metric_spec(metric, catalog) do
    case Map.get(catalog, metric["ref"]) do
      nil -> metric
      definition -> Map.merge(metric, %{"label" => definition.label, "unit" => definition.unit, "direction" => metric["direction"] || definition.default_direction})
    end
  end

  @spec order([map()]) :: [map()]
  def order(items) do
    Enum.sort_by(items, fn item ->
      {if(item.status in ["collecting", "active"], do: 0, else: 1), -timestamp(item.created_at), item.id}
    end)
  end

  defp kind_label(%{"kind" => "before_after"}), do: "Before/after"

  defp kind_label(%{"kind" => "ab", "cohorts" => cohorts}) when is_list(cohorts) do
    case length(cohorts) do
      2 -> "A/B"
      3 -> "A/B/C"
      4 -> "A/B/C/D"
      count -> "#{count} cohorts"
    end
  end

  defp kind_label(_design), do: "Unknown design"

  defp design_summary(%{"kind" => "before_after", "change" => change}) when is_map(change),
    do: "#{change["ref"] || "Unknown change"} · #{change["time"] || "Unknown time"}"

  defp design_summary(%{"kind" => "ab", "cohorts" => cohorts}) when is_list(cohorts),
    do: Enum.map_join(cohorts, " · ", &Map.get(&1, "label", "Unknown cohort"))

  defp design_summary(_design), do: "Unknown design"

  defp window_labels(windows) when is_map(windows) do
    for key <- ~w(before after observation), is_map(windows[key]) do
      %{label: String.capitalize(key), text: "#{windows[key]["start"] || "Unknown start"} → #{windows[key]["end"] || "Open"}"}
    end
  end

  defp window_labels(_windows), do: []

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> DateTime.to_unix(time, :microsecond)
      {:error, _reason} -> 0
    end
  end

  defp timestamp(_value), do: 0
end

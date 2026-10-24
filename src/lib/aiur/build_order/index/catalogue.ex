defmodule Aiur.BuildOrder.Index.Catalogue do
  @moduledoc false
  alias Aiur.BuildOrder.{Epic, FeatureStats, SourceFreshness}
  alias Aiur.BuildOrder.Index.Rows
  alias Aiur.Heroicons
  @statuses Map.new(~w(done failed not_planned closed running queued open)a, &{Atom.to_string(&1), &1})

  @spec general(map()) :: {:ok, list()} | {:error, :epic_config_unavailable | :settings_loading}
  def general(%{settings: {:ok, %{build_order: %{general_epics: general}}}}) when is_list(general), do: {:ok, general}
  def general(%{settings: {:error, :workflow_not_loaded}}), do: {:error, :settings_loading}
  def general(%{settings: _read_result}), do: {:error, :epic_config_unavailable}
  def general(%{read_stale: stale}) when is_map(stale), do: {:error, :settings_loading}
  def general(_parts), do: {:error, :settings_loading}

  @spec registry(map()) :: map() | :unknown
  def registry(%{features: {:ok, registry}}), do: registry
  def registry(_), do: :unknown

  @spec build(map(), list(), map(), integer()) :: map()
  def build(parts, general, rows, now) do
    registry = registry(parts)
    features = if registry == :unknown, do: %{}, else: registry.features
    sorted = Enum.sort_by(features, fn {slug, f} -> {SourceFreshness.ms(f.from) || :unknown, slug} end)
    facts = Map.new(rows, fn {_id, row} -> {row.num, fact(parts, row)} end) |> include_undated(parts)
    stats = if registry == :unknown, do: %{}, else: FeatureStats.compute_all(registry, facts, now: now)

    feature_metadata = feature_metadata(parts)

    feature_rows = feature_rows(sorted, feature_metadata, stats)
    epics = general_epics(general)
    feature_epics = feature_epics(sorted, feature_metadata)
    order = Enum.map(general, & &1.key) ++ Enum.flat_map(sorted, fn {_, f} -> Enum.map(f.epics, & &1.key) end) ++ ["unsorted"]
    %{features: feature_rows, epics: epics |> Map.merge(feature_epics) |> Map.put("unsorted", Epic.unsorted()), order: order}
  end

  defp feature_rows(sorted, metadata_by_id, stats) do
    Map.new(sorted, fn {slug, feature} ->
      metadata = Map.get(metadata_by_id, slug, %{})

      {slug,
       %{
         key: slug,
         label: feature.label,
         hue: feature.hue,
         icon: Map.get(metadata, "icon") || Heroicons.generic_name(),
         svg: Heroicons.svg(metadata["icon"]),
         summary: metadata["summary"],
         wave: wave_label(metadata["wave"]),
         epics: Enum.map(feature.epics, & &1.key),
         from: SourceFreshness.ms(feature.from),
         to: SourceFreshness.ms(feature.to),
         stats: FeatureStats.to_json(stats[slug])
       }}
    end)
  end

  defp general_epics(general) do
    Map.new(general, fn epic ->
      {epic.key, epic |> Map.take([:key, :label, :hue, :icon]) |> Map.put(:svg, Heroicons.svg(epic.icon)) |> Map.put(:general, true)}
    end)
  end

  defp feature_epics(sorted, metadata_by_id) do
    for {slug, feature} <- sorted, epic <- feature.epics, into: %{}, do: {epic.key, feature_epic(slug, feature, epic, metadata_by_id)}
  end

  defp feature_epic(slug, feature, epic, metadata_by_id) do
    metadata = Map.get(metadata_by_id, slug, %{})

    %{
      key: epic.key,
      label: epic.label,
      hue: feature.hue,
      icon: Map.get(metadata, "icon") || Heroicons.generic_name(),
      svg: Heroicons.svg(Map.get(metadata, "icon")),
      summary: Map.get(metadata, "summary"),
      wave: wave_label(Map.get(metadata, "wave")),
      feature: slug,
      temp: true
    }
  end

  defp feature_metadata(%{pack_metadata: %{"workstreams" => workstreams}}) when is_list(workstreams),
    do: Map.new(workstreams, fn workstream -> {workstream["id"], workstream} end)

  defp feature_metadata(_parts), do: %{}

  defp wave_label(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp wave_label(value) when is_binary(value), do: value
  defp wave_label(_value), do: nil

  defp include_undated(facts, parts) do
    Enum.reduce(Rows.history(parts), facts, fn {number, row}, acc ->
      Map.put_new_lazy(acc, number, fn -> FeatureStats.fact(row, historic_status(row.lifecycle), {:unknown, :progress}) end)
    end)
  end

  defp historic_status(%{state: :closed, state_reason: :completed}), do: :done
  defp historic_status(%{state: :closed, state_reason: :not_planned}), do: :not_planned
  defp historic_status(%{state: :closed}), do: :closed
  defp historic_status(_), do: :unknown

  defp fact(parts, row) do
    historic = Map.get(parts.resolved_history, row.num, :missing)

    progress = if is_integer(row.pct), do: {:known, row.pct}, else: {:unknown, :progress}
    FeatureStats.fact(historic, Map.fetch!(@statuses, row.status), progress)
  end
end

defmodule Aiur.BuildOrder.Index.Catalogue do
  @moduledoc false
  alias Aiur.BuildOrder.{Epic, FeatureStats, SourceFreshness}
  alias Aiur.BuildOrder.Index.Rows
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

    features =
      Map.new(sorted, fn {slug, f} ->
        {slug, %{key: slug, label: f.label, hue: f.hue, epics: Enum.map(f.epics, & &1.key), from: SourceFreshness.ms(f.from), to: SourceFreshness.ms(f.to), stats: FeatureStats.to_json(stats[slug])}}
      end)

    epics = Map.new(general, fn e -> {e.key, e |> Map.take([:key, :label, :hue, :icon]) |> Map.put(:general, true)} end)
    feature_epics = for {slug, f} <- sorted, e <- f.epics, into: %{}, do: {e.key, %{key: e.key, label: e.label, hue: f.hue, icon: "layers", feature: slug, temp: true}}
    order = Enum.map(general, & &1.key) ++ Enum.flat_map(sorted, fn {_, f} -> Enum.map(f.epics, & &1.key) end) ++ ["unsorted"]
    %{features: features, epics: epics |> Map.merge(feature_epics) |> Map.put("unsorted", Epic.unsorted()), order: order}
  end

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

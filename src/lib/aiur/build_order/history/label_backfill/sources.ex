defmodule Aiur.BuildOrder.History.LabelBackfill.Sources do
  @moduledoc false
  alias Aiur.BuildOrder.{EpicOverrides, Features, History}
  alias Aiur.BuildOrder.Features.LabelProjection
  alias Aiur.BuildOrder.History.LabelBackfill.Rules

  @spec readers(keyword()) :: map()
  def readers(opts) do
    Map.merge(
      %{
        features: fn -> Features.snapshot() end,
        owner: &Features.owner/1,
        projection: &LabelProjection.label_states/1,
        mark: &LabelProjection.mark_labelled/3,
        overrides: fn -> EpicOverrides.all() end,
        history: &History.rows/1,
        health: &History.health/0,
        settings: &Aiur.Config.settings/0,
        tracker_supported: fn ->
          case Aiur.Config.settings() do
            {:ok, %{tracker: %{kind: "linear"}}} -> false
            _ -> true
          end
        end
      },
      Keyword.get(opts, :readers, %{})
    )
  end

  @spec plan(map(), keyword()) :: map()
  def plan(readers, opts) do
    {features, unknown} = features(readers)
    {epics, skipped, unknown} = epics(readers, Keyword.get(opts, :epic_labels, false), unknown)
    candidates = Enum.sort_by(features ++ epics, &{&1.ticket, &1.label})
    {rows, health} = history(readers, Enum.map(candidates, & &1.ticket))
    entries = Enum.map(candidates, &entry(&1, rows, health))
    deferred = counts(entries, :defer)
    writes = Enum.filter(entries, &(&1.decision == :write))
    unknown = Enum.uniq(unknown ++ if(map_size(deferred) > 0, do: Map.keys(deferred), else: []))
    feature_count = write_count(entries, writes, unknown, :feature, [:features, :projection])
    epic_count = write_count(entries, writes, unknown, :epic, [:overrides, :catalog])
    ensures = writes |> Enum.filter(&(&1.kind == :feature)) |> Enum.map(& &1.label) |> Enum.uniq() |> length()
    total = if unknown == [], do: length(writes) + ensures, else: :unknown
    ensures = if feature_count == :unknown, do: :unknown, else: ensures

    %{
      items: entries,
      tracker: if(readers.tracker_supported.(), do: :supported, else: :unsupported),
      writes: %{feature: feature_count, epic: epic_count},
      ensure: ensures,
      total: total,
      skipped: Map.merge(counts(entries, :skip), skipped, fn _key, a, b -> a + b end),
      deferred: deferred,
      unknown: unknown,
      hours: if(is_integer(total), do: ceil(total / max(Keyword.get(opts, :per_hour, 60), 1)), else: :unknown),
      cost: "1 Core request per label (code-derived, not measured; C13-T00 census 2026-10-25); ensure calls additional"
    }
  end

  defp write_count(entries, writes, unknown, kind, sources) do
    deferred? = Enum.any?(entries, &(&1.kind == kind and match?({:defer, _}, &1.decision)))
    if Enum.any?(sources, &(&1 in unknown)) or deferred?, do: :unknown, else: Enum.count(writes, &(&1.kind == kind))
  end

  defp features(readers) do
    case readers.features.() do
      {:ok, %{owners: owners}} -> feature_states(readers, owners)
      _ -> {[], [:features]}
    end
  end

  defp feature_states(readers, owners) do
    case readers.projection.(Map.keys(owners)) do
      {:ok, states} ->
        {Enum.map(owners, fn {n, owner} ->
           %{ticket: n, kind: :feature, slug_or_epic: owner.feature, label: "feature:" <> owner.feature, confirmed: owner.confirmed, projection: states[n]}
         end), []}

      _ ->
        {[], [:projection]}
    end
  end

  defp epics(_readers, false, unknown), do: {[], %{}, unknown}

  defp epics(readers, true, unknown) do
    with {:ok, overrides, _} <- readers.overrides.(), {:ok, %{build_order: %{general_epics: catalog}}} <- readers.settings.() do
      labels = Map.new(catalog, &{&1.key, &1.labels})
      {items, skipped} = Enum.reduce(overrides, {[], 0}, &epic(&1, &2, labels))
      {items, %{no_matcher: skipped}, unknown}
    else
      _ -> {[], %{}, [:overrides, :catalog | unknown]}
    end
  end

  defp epic({n, override}, {items, skipped}, labels) do
    case Map.get(labels, override.epic, []) do
      [label | _] -> {[%{ticket: n, kind: :epic, slug_or_epic: override.epic, label: label, confirmed: override.confirmed} | items], skipped}
      [] -> {items, skipped + 1}
    end
  end

  defp history(readers, numbers) do
    case readers.history.(Enum.uniq(numbers)) do
      {:ok, rows, health} -> {Map.new(rows, &{&1.number, &1}), health.state}
      _ -> {%{}, :unknown}
    end
  end

  defp entry(candidate, rows, health) do
    row = Map.get(rows, candidate.ticket, :unknown)
    Map.merge(candidate, %{decision: Rules.eligible(candidate, row, %{history_state: health}), seen_at: if(row == :unknown, do: nil, else: row.observed_at)})
  end

  defp counts(entries, tag) do
    entries
    |> Enum.flat_map(fn
      %{decision: {^tag, reason}} -> [reason]
      _ -> []
    end)
    |> Enum.frequencies()
  end

  @spec current?(map(), map()) :: boolean() | :unknown
  def current?(%{kind: :feature} = item, readers) do
    case readers.owner.(item.ticket) do
      {:ok, %{feature: slug, confirmed: true}} -> slug == item.slug_or_epic
      {:error, _} -> :unknown
      _ -> false
    end
  end

  def current?(%{kind: :epic} = item, readers) do
    case readers.overrides.() do
      {:ok, overrides, _} -> match?(%{epic: epic, confirmed: true} when epic == item.slug_or_epic, overrides[item.ticket])
      _ -> :unknown
    end
  end
end

defmodule Aiur.BuildOrder.Index.FeatureBars do
  @moduledoc """
  One merged/total bar per product feature, for the Features list and the feature filter.

  A feature's tickets are its registry members plus every history row labelled
  `feature:<slug>`. A ticket is merged when it closed with a merged PR, or closed as
  completed with no PR. A ticket closed without merging (not planned, duplicate, or an
  unmerged PR) is left out of the total, so a finished feature reaches merged == total.
  Rows whose state is unknown stay in the total as unmerged, so progress is never overstated.
  """
  alias Aiur.BuildOrder.Features.FeatureData

  @spec compute(map(), integer()) :: [map()] | nil
  def compute(parts, now) do
    case parts[:history] do
      {:ok, %{rows: rows}} ->
        registry = registry(parts[:features])
        order = feature_order(parts[:settings])

        rows
        |> members(registry)
        |> Enum.map(fn {slug, numbers} -> bar(slug, Enum.map(numbers, &Map.get(rows, &1)), registry, parts[:labels]) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn bar -> {Enum.find_index(order, &(&1 == bar.key)) || length(order), bar.since || now, bar.key} end)
        |> Enum.map(&Map.delete(&1, :since))

      _unavailable ->
        nil
    end
  end

  defp registry({:ok, %{features: features, owners: owners}}), do: %{features: features, owners: owners}
  defp registry(_unknown), do: %{features: %{}, owners: %{}}

  defp feature_order({:ok, %{build_order: %{feature_order: order}}}) when is_list(order), do: order
  defp feature_order(_settings), do: []

  defp members(rows, registry) do
    owned = Enum.map(registry.owners, fn {number, owner} -> {owner.feature, number} end)
    labelled = for {number, %{labels: labels}} <- rows, is_list(labels), label <- labels, slug <- [label_slug(label)], FeatureData.slug?(slug), do: {slug, number}

    (owned ++ labelled)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {slug, numbers} -> {slug, Enum.uniq(numbers)} end)
  end

  defp bar(slug, rows, registry, label_snapshot) do
    counted = Enum.reject(rows, &closed_unmerged?/1)
    total = length(counted)
    registered = registry.features[slug]

    if total > 0 do
      %{
        key: slug,
        label: if(registered, do: registered.label, else: label_name(slug, rows, label_snapshot)),
        merged: Enum.count(counted, &merged?/1),
        total: total,
        since: rows |> Enum.map(&created_ms/1) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
      }
    end
  end

  defp merged?(%{lifecycle: %{state: :closed}, merged_at: %DateTime{}}), do: true
  defp merged?(%{lifecycle: %{state: :closed, state_reason: :completed}} = row), do: not unmerged_pr?(row)
  defp merged?(_row), do: false

  defp closed_unmerged?(%{lifecycle: %{state: :closed}} = row), do: not merged?(row)
  defp closed_unmerged?(_row), do: false

  defp unmerged_pr?(%{pr_number: number, merged_at: :none}) when is_integer(number), do: true
  defp unmerged_pr?(_row), do: false

  defp label_name(slug, rows, label_snapshot) do
    current_description = current_label_description(slug, label_snapshot)
    labels = Enum.flat_map(rows, &Map.get(&1, :labels, []))
    current_description || Enum.find_value(labels, slug, fn label -> if label_slug(label) == slug, do: label_name(label) end)
  end

  defp current_label_description(slug, {:ok, issues, _observed_at}) do
    description = issues |> Map.values() |> Enum.find_value(fn issue -> get_in(issue, [:label_descriptions, "feature:" <> slug]) end)
    display_description(description)
  end

  defp current_label_description(_slug, _snapshot), do: nil
  defp display_description("Feature collection: " <> rest), do: rest
  defp display_description(value) when is_binary(value) and value != "", do: value
  defp display_description(_value), do: nil

  defp label_slug("feature:" <> rest), do: rest |> String.split([" (", " — "], parts: 2) |> hd()
  defp label_slug(_label), do: nil

  defp label_name("feature:" <> rest) do
    case String.split(rest, " (", parts: 2) do
      [_slug, description] -> String.replace_suffix(description, ")", "") |> String.replace_prefix("Feature collection: ", "")
      _ -> nil
    end
  end

  defp label_name(_label), do: nil

  defp created_ms(%{created_at: %DateTime{} = at}), do: DateTime.to_unix(at, :millisecond)
  defp created_ms(_row), do: nil
end

defmodule Aiur.BuildOrder.Index.FeatureBars do
  @moduledoc """
  One merged/total bar per product feature, for the Features list and the feature filter.

  A feature's tickets are its registry members plus every history row labelled
  `feature:<slug>`. A ticket is merged when it closed with a merged PR, or closed as
  completed with no PR. A ticket closed without merging (not planned, duplicate, or an
  unmerged PR) is left out of the total, so a finished feature reaches merged == total.
  Rows whose state is unknown stay in the total as unmerged, so progress is never overstated.

  A row name is the registry label, then the label description, then the title-cased slug.
  Logical ids such as `MP-E1` and `BO:` are not part of a product name, so they are stripped
  from every source.

  The description comes from the repository's own label record first
  (`Aiur.GitHub.LabelCatalogue`), then from the open-issue label observation, then from the
  description a history row captured. The first source names a label whether or not a ticket
  still wears it, which is what a feature whose tickets have all merged needs.
  """
  alias Aiur.BuildOrder.Features.FeatureData

  # Logical ids ("MP-E1", "MP-N2", "BO:") prefix the names Aiur and GitHub store; they are
  # not part of the product name a row shows. "BO:" also opens the Build Order program.
  @logical_id_prefix ~r/\A(?:[A-Z][A-Z0-9]*-[A-Z]{0,2}\d+|[A-Z]{2,}\d+|[A-Z][A-Z0-9]*:)\s+/
  @logical_id_only ~r/\A(?:[A-Z][A-Z0-9]*-[A-Z]{0,2}\d+|[A-Z]{2,}\d+|[A-Z][A-Z0-9]*:?)\z/
  @wave_suffix ~r/\s+\(wave [^)]+\)\z/

  @spec compute(map(), integer()) :: [map()] | nil
  def compute(parts, now) do
    case parts[:history] do
      {:ok, %{rows: rows}} ->
        registry = registry(parts[:features])
        order = feature_order(parts[:settings])

        rows
        |> members(registry)
        |> Enum.reject(fn {slug, _numbers} -> String.starts_with?(slug, "bo-") end)
        |> Enum.map(fn {slug, numbers} -> bar(slug, Enum.map(numbers, &Map.get(rows, &1)), registry, parts) end)
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

  defp bar(slug, rows, registry, parts) do
    counted = Enum.reject(rows, &closed_unmerged?/1)
    total = length(counted)
    registered = registry.features[slug]

    if total > 0 do
      %{
        key: slug,
        label: display_label(slug, registered, rows, parts),
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

  # A row name is the registry label, then the label description, then the title-cased slug.
  defp display_label(slug, registered, rows, parts) do
    registry_name(registered) || description_name(slug, rows, parts) || title_slug(slug)
  end

  defp registry_name(%{label: label}) when is_binary(label), do: label |> display_feature_label() |> present()
  defp registry_name(_registered), do: nil

  defp description_name(slug, rows, parts) do
    case catalogue_label_description(slug, parts) || current_label_description(slug, parts[:labels]) || historical_label_description(slug, rows) do
      description when is_binary(description) -> display_description(description)
      _unknown -> nil
    end
  end

  # The repository's own label record names a label whether or not a ticket wears it.
  defp catalogue_label_description(slug, %{label_catalogue: {:ok, descriptions, _read_at}}) when is_map(descriptions),
    do: descriptions["feature:" <> slug]

  defp catalogue_label_description(_slug, _parts), do: nil

  defp current_label_description(slug, {:ok, issues, _observed_at}) do
    issues |> Map.values() |> Enum.find_value(fn issue -> get_in(issue, [:label_descriptions, "feature:" <> slug]) end)
  end

  defp current_label_description(_slug, _snapshot), do: nil

  defp historical_label_description(slug, rows) do
    Enum.find_value(rows, fn row ->
      descriptions = Map.get(row, :label_descriptions)
      if is_map(descriptions), do: descriptions["feature:" <> slug]
    end)
  end

  # The row shows one short product name: the description without its "Feature collection: "
  # prefix and without the " (detail)" tail that follows it. A description written for the
  # logical id is capitalised so it still reads as a name once the id is stripped.
  defp display_description("Feature collection: " <> rest), do: display_description(rest)

  defp display_description(value) when is_binary(value) do
    value |> String.split(" (", parts: 2) |> hd() |> without_id_prefix(&sentence_case/1) |> present()
  end

  # Registry labels are short Aiur-authored names: a stripped id leaves words to title-case,
  # while a label that never carried an id stays exactly as its author wrote it.
  defp display_feature_label(label) when is_binary(label) do
    label |> without_program() |> without_id_prefix(&title_words/1) |> present()
  end

  defp without_id_prefix(label, recase) do
    case without_logical_id(label) do
      ^label -> label
      rest -> recase.(rest)
    end
  end

  # "BO: <program> — <feature> (wave 0b)" keeps only the feature part.
  defp without_program(label) do
    case String.replace(label, @wave_suffix, "") do
      "BO: " <> rest ->
        case String.split(rest, " — ", parts: 2) do
          [_program, feature] -> String.replace(feature, @wave_suffix, "")
          _no_program -> rest
        end

      plain ->
        plain
    end
  end

  defp without_logical_id(label) do
    case Regex.run(@logical_id_prefix, label) do
      [prefix] -> String.replace_prefix(label, prefix, "")
      _none -> if Regex.match?(@logical_id_only, label), do: "", else: label
    end
  end

  defp sentence_case(value) do
    case String.next_grapheme(value) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> value
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp title_words(label), do: label |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)

  defp label_slug("feature:" <> rest), do: rest |> String.split([" (", " — "], parts: 2) |> hd()
  defp label_slug(_label), do: nil

  defp title_slug(slug) do
    slug |> String.split("-") |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp created_ms(%{created_at: %DateTime{} = at}), do: DateTime.to_unix(at, :millisecond)
  defp created_ms(_row), do: nil
end

defmodule Aiur.BuildOrder.Epics.Projection do
  @moduledoc """
  Epic journal projection plus the read-time migration from feature records.

  An epic is a first-class record above features: slug, label, optional icon,
  hue, an optional Build Order root and the ordered feature slugs it holds. The
  records live in `build-features/epics.ndjson`; `features.ndjson` keeps its v1
  format and is never rewritten.

  Because the feature journal is never rewritten, a Build Order root's imported
  feature (`bo-<n>`, source `import:build-order`) projects as an epic at read
  time, and that feature's legacy "epics" project as lane assignments. A stored
  record for the same slug wins for label, icon and hue; its lanes still come
  from the registry feature, so an operator's epic colour never hides the lanes
  the members actually carry.
  """

  @type epic :: map()

  @spec empty() :: map()
  def empty, do: %{epics: %{}, seq: 0}

  @spec fold(map(), map()) :: {:ok, map()} | {:error, term()}
  def fold(projection, %{seq: seq} = record) when seq == projection.seq + 1 do
    Enum.reduce_while(record.events, {:ok, projection}, fn event, {:ok, acc} ->
      case apply_event(acc, event, record) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
    |> finish(record)
  end

  def fold(_, _), do: {:error, {:invariant, :sequence}}

  @doc """
  Effective epics in display order: journal records merged with the read-time
  derivation from `features`, a `Aiur.BuildOrder.Features` projection.
  """
  @spec epics(map(), map()) :: [epic()]
  def epics(stored, features) when is_map(stored) and is_map(features) do
    stored
    |> merge_derived(features)
    |> Map.values()
    |> Enum.sort_by(&order/1)
  end

  @doc "Whether a feature slug projects as an epic without a stored record."
  @spec derived?(map(), term()) :: boolean()
  def derived?(features, slug), do: MapSet.member?(imported(features), slug)

  defp finish({:error, _} = error, _record), do: error
  defp finish({:ok, projection}, record), do: {:ok, %{projection | seq: record.seq}}

  defp apply_event(projection, %{type: "epic.created", epic: epic, at: at}, record) do
    if Map.has_key?(projection.epics, epic.slug) or root_taken?(projection, epic.root) do
      {:error, {:invariant, :epic_exists}}
    else
      {:ok, put_in(projection.epics[epic.slug], created(epic, at, record.source))}
    end
  end

  defp apply_event(projection, %{type: "epic.updated", epic: slug, changes: changes, at: at}, _record) do
    case Map.fetch(projection.epics, slug) do
      {:ok, epic} -> {:ok, put_in(projection.epics[slug], updated(epic, changes, at))}
      :error -> {:error, {:invariant, :unknown_epic}}
    end
  end

  defp apply_event(projection, %{type: "epic.feature_added", epic: slug, feature: feature, at: at}, _record) do
    with {:ok, epic} <- fetch(projection, slug),
         :ok <- unclaimed(projection, slug, feature) do
      {:ok, put_in(projection.epics[slug], %{epic | features: epic.features ++ [feature], updated_at: at})}
    end
  end

  defp apply_event(projection, %{type: "epic.feature_removed", epic: slug, feature: feature, at: at}, _record) do
    with {:ok, epic} <- fetch(projection, slug) do
      {:ok, put_in(projection.epics[slug], %{epic | features: List.delete(epic.features, feature), updated_at: at})}
    end
  end

  defp apply_event(_projection, _event, _record), do: {:error, {:invariant, :unknown_event}}

  defp created(epic, at, source) do
    epic
    |> Map.put(:features, [])
    |> Map.put(:lanes, [])
    |> Map.put(:label_source, if(source == "import:build-order", do: :import, else: :operator))
    |> Map.put(:created_at, at)
    |> Map.put(:updated_at, at)
  end

  defp updated(epic, changes, at) do
    epic = epic |> Map.merge(changes) |> Map.put(:updated_at, at)
    if Map.has_key?(changes, :label), do: Map.put(epic, :label_source, :operator), else: epic
  end

  defp fetch(projection, slug) do
    case Map.fetch(projection.epics, slug) do
      {:ok, epic} -> {:ok, epic}
      :error -> {:error, {:invariant, :unknown_epic}}
    end
  end

  defp root_taken?(_projection, nil), do: false
  defp root_taken?(projection, root), do: Enum.any?(projection.epics, fn {_slug, epic} -> epic.root == root end)

  defp unclaimed(projection, slug, feature) do
    if Enum.any?(projection.epics, fn {other, epic} -> other != slug and feature in epic.features end),
      do: {:error, {:invariant, :feature_in_two_epics}},
      else: :ok
  end

  defp merge_derived(stored, features) do
    owners = owners_by_lane(features)

    derived =
      features
      |> imported()
      |> Enum.sort()
      |> Enum.reduce(%{}, fn slug, acc ->
        case Map.get(features.features, slug) do
          nil -> acc
          feature -> Map.put(acc, slug, derive(slug, feature, owners))
        end
      end)

    Map.merge(derived, stored.epics, fn _slug, derivation, record -> %{record | lanes: derivation.lanes} end)
  end

  defp imported(features), do: Map.get(features, :imported, MapSet.new())

  defp owners_by_lane(features) do
    features.owners
    |> Enum.reduce(%{}, fn {number, owner}, acc -> Map.update(acc, owner.epic, [number], &[number | &1]) end)
    |> Map.new(fn {key, numbers} -> {key, Enum.sort(numbers)} end)
  end

  defp derive(slug, feature, owners) do
    %{
      slug: slug,
      label: feature.label,
      icon: nil,
      hue: feature.hue,
      root: root_number(slug),
      features: [],
      lanes: lanes(feature, owners),
      label_source: :import,
      created_at: feature.created_at,
      updated_at: feature.updated_at
    }
  end

  defp lanes(feature, owners) do
    for epic <- feature.epics do
      %{key: epic.key, lane: lane_key(epic.key), label: epic.label, icon: Map.get(epic, :icon), members: Map.get(owners, epic.key, [])}
    end
  end

  # Legacy lane epics are named `f-bo-<root>-<lane>`; the unsuffixed key is the
  # root's "unassigned" bucket. Anything else is not a lane assignment.
  defp lane_key(key) do
    cond do
      match = Regex.run(~r/^f-bo-[0-9]+-(.+)$/, key) -> Enum.at(match, 1)
      Regex.match?(~r/^f-bo-[0-9]+$/, key) -> :unassigned
      true -> key
    end
  end

  defp root_number(slug) do
    case Regex.run(~r/^bo-([0-9]{1,10})$/, slug) do
      [_, number] -> String.to_integer(number)
      nil -> nil
    end
  end

  defp order(epic) do
    {if(epic.root, do: 0, else: 1), epic.root || 0, unix(epic.created_at), epic.slug}
  end

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp unix(_), do: 0
end

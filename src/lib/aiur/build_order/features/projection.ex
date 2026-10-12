defmodule Aiur.BuildOrder.Features.Projection do
  @moduledoc false

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

  defp finish({:error, _} = error, _record), do: error

  defp finish({:ok, projection}, record) do
    with :ok <- invariants(projection) do
      provenance = Map.take(record, [:seq, :recorded_at, :source, :actor])
      events = Enum.map(record.events, &Map.merge(&1, provenance))
      {:ok, %{projection | seq: record.seq, events: projection.events ++ events}}
    end
  end

  defp apply_event(projection, %{type: "feature.created", feature: slug, data: data}, _record) do
    if Map.has_key?(projection.features, slug) or data.slug != slug do
      {:error, {:invariant, :feature_exists}}
    else
      {:ok, put_in(projection.features[slug], data)}
    end
  end

  defp apply_event(projection, event, record) do
    case Map.fetch(projection.features, event.feature) do
      {:ok, feature} -> apply_existing(projection, feature, event, record)
      :error -> {:error, {:invariant, :unknown_feature}}
    end
  end

  defp apply_existing(projection, feature, %{type: "feature.updated", changes: changes, at: at}, _record) do
    if valid_relabels?(feature.epics, Map.get(changes, :epics, feature.epics)) do
      updated = feature |> Map.merge(changes) |> Map.put(:updated_at, at)
      {:ok, put_in(projection.features[feature.slug], updated)}
    else
      {:error, {:invariant, :epic_relabel}}
    end
  end

  defp apply_existing(projection, feature, %{type: "feature.epic_added", epic: epic, at: at}, _record) do
    updated = %{feature | epics: feature.epics ++ [epic], updated_at: at}
    {:ok, put_in(projection.features[feature.slug], updated)}
  end

  defp apply_existing(projection, feature, %{type: "member.added"} = event, record) do
    case Map.get(projection.owners, event.number) do
      %{feature: other} when other != feature.slug ->
        {:error, {:invariant, :owner}}

      %{confirmed: true} when not event.confirmed ->
        {:error, {:invariant, :confirmed_downgrade}}

      old ->
        owner = %{
          feature: feature.slug,
          epic: event.epic,
          joined_at: if(old, do: old.joined_at, else: event.at),
          at_basis: if(old, do: old.at_basis, else: event.at_basis),
          source: record.source,
          actor: record.actor,
          confirmed: event.confirmed
        }

        {:ok, put_in(projection.owners[event.number], owner)}
    end
  end

  defp apply_existing(projection, feature, %{type: "member.removed", number: number}, _record) do
    case Map.get(projection.owners, number) do
      %{feature: slug} when slug == feature.slug -> {:ok, %{projection | owners: Map.delete(projection.owners, number)}}
      _ -> {:error, {:invariant, :not_member}}
    end
  end

  defp apply_existing(projection, feature, %{type: "also.added", number: number}, _record) do
    links = projection.also |> Map.get(number, MapSet.new()) |> MapSet.put(feature.slug)
    {:ok, put_in(projection.also[number], links)}
  end

  defp apply_existing(projection, feature, %{type: "also.removed", number: number}, _record) do
    links = projection.also |> Map.get(number, MapSet.new()) |> MapSet.delete(feature.slug)
    also = if MapSet.size(links) == 0, do: Map.delete(projection.also, number), else: Map.put(projection.also, number, links)
    {:ok, %{projection | also: also}}
  end

  defp apply_existing(projection, feature, %{type: "baseline.set", at: at, members: members}, _record) do
    owned = for {number, %{feature: slug}} <- projection.owners, slug == feature.slug, into: MapSet.new(), do: number

    if MapSet.new(members) == owned and length(members) == MapSet.size(owned) do
      updated = %{feature | baseline: %{at: at, members: owned}, updated_at: at}
      {:ok, put_in(projection.features[feature.slug], updated)}
    else
      {:error, {:invariant, :baseline_members}}
    end
  end

  defp apply_existing(_, _, _, _), do: {:error, {:invariant, :unknown_event}}

  defp valid_relabels?(before, after_epics), do: Enum.map(before, & &1.key) == Enum.map(after_epics, & &1.key)

  defp invariants(projection) do
    keys = for {_slug, feature} <- projection.features, epic <- feature.epics, do: epic.key

    cond do
      "unsorted" in keys or length(keys) != MapSet.size(MapSet.new(keys)) -> {:error, {:invariant, :epic_keys}}
      not Enum.all?(projection.owners, &valid_owner?(&1, projection)) -> {:error, {:invariant, :owner_epic}}
      not Enum.all?(projection.also, &valid_also?(&1, projection)) -> {:error, {:invariant, :also}}
      true -> :ok
    end
  end

  defp valid_owner?({_number, owner}, projection) do
    case Map.get(projection.features, owner.feature) do
      nil -> false
      feature -> Enum.any?(feature.epics, &(&1.key == owner.epic))
    end
  end

  defp valid_also?({number, links}, projection) do
    owner = Map.get(projection.owners, number)
    Enum.all?(links, &(Map.has_key?(projection.features, &1) and (is_nil(owner) or owner.feature != &1)))
  end
end

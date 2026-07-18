defmodule Aiur.CurrentRunProjections.WeightFacts do
  @moduledoc false

  alias Aiur.TrackerIdentity

  @spec resolve([map()], map(), [map()], map(), map()) :: map()
  def resolve(members, status, facts, retained, availability) do
    fact_index = identity_index(facts)
    retained = retain_members(retained, members)

    {entries, retained, stale?} =
      Enum.reduce(members, {[], retained, false}, fn member, accumulator ->
        resolve_member(member, fact_index, accumulator)
      end)

    race_signature = race_signature(members, status, facts, availability)
    health = health(availability, stale?, not is_nil(race_signature))

    %{
      entries: Enum.reverse(entries),
      retained: retained,
      health: health,
      race_signature: race_signature
    }
  end

  defp resolve_member(member, fact_index, {entries, retained, stale?}) do
    key = member_key(member)

    case Map.fetch(fact_index, key) do
      {:ok, fact} -> current_fact(fact, key, entries, retained, stale?)
      :error -> retained_fact(member, Map.get(retained, key), entries, retained, stale?)
    end
  end

  defp current_fact(fact, key, entries, retained, stale?) do
    if valid_complexity?(Map.get(fact, :complexity)) do
      {[fact | entries], Map.put(retained, key, fact), stale?}
    else
      {[fact | entries], Map.delete(retained, key), stale?}
    end
  end

  defp retained_fact(%{terminal?: true}, fact, entries, retained, stale?) when is_map(fact),
    do: {[fact | entries], retained, stale?}

  defp retained_fact(_member, fact, entries, retained, _stale?) when is_map(fact),
    do: {[fact | entries], retained, true}

  defp retained_fact(_member, nil, entries, retained, _stale?), do: {entries, retained, true}

  defp retain_members(retained, members) do
    keys = members |> Enum.map(&member_key/1) |> Enum.reject(&is_nil/1)
    Map.take(retained, keys)
  end

  defp health(%{status: false}, _stale?, _race?), do: :unavailable
  defp health(%{status_facts: false}, _stale?, _race?), do: :unavailable
  defp health(_availability, true, _race?), do: :stale
  defp health(_availability, _stale?, true), do: :stale
  defp health(_availability, _stale?, _race?), do: :healthy

  defp race_signature(_members, _status, _facts, %{status: false}), do: nil
  defp race_signature(_members, _status, _facts, %{status_facts: false}), do: nil

  defp race_signature(members, status, facts, _availability) do
    active_keys =
      members
      |> Enum.reject(&(Map.get(&1, :terminal?) == true))
      |> identity_keys()

    status_keys =
      [:running, :retrying, :idle]
      |> Enum.flat_map(&List.wrap(Map.get(status, &1, [])))
      |> identity_keys()
      |> MapSet.intersection(active_keys)

    fact_keys = facts |> identity_keys() |> MapSet.intersection(active_keys)
    mismatch = MapSet.symmetric_difference(status_keys, fact_keys)

    if MapSet.size(mismatch) == 0,
      do: nil,
      else: mismatch |> MapSet.to_list() |> Enum.sort() |> :erlang.phash2()
  end

  defp identity_keys(entries) do
    entries
    |> Enum.map(&member_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp identity_index(entries) do
    Enum.reduce(entries, %{}, fn entry, index ->
      case member_key(entry) do
        nil -> index
        key -> Map.put(index, key, entry)
      end
    end)
  end

  defp member_key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)

  defp member_key(member) when is_map(member) do
    identity = Map.get(member, :identity) || Map.get(member, :tracker_identity)
    TrackerIdentity.github_key(identity)
  end

  defp member_key(_member), do: nil
  defp valid_complexity?(value), do: is_integer(value) and value in 1..5
end

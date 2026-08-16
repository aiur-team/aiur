defmodule Aiur.CurrentRunProjections.WeightFacts do
  @moduledoc false

  alias Aiur.TrackerIdentity

  @spec resolve([map()], map(), [map()], map(), map()) :: map()
  def resolve(members, status, facts, retained, availability) do
    fact_index = fact_index(facts, availability)
    retained = retain_members(retained, members)

    {entries, retained, stale?, freshness} =
      Enum.reduce(members, {[], retained, false, %{}}, fn member, accumulator ->
        resolve_member(member, fact_index, accumulator)
      end)

    race_signature = race_signature(members, status, facts, availability)
    health = health(availability, stale?, not is_nil(race_signature))

    %{
      entries: Enum.reverse(entries),
      retained: retained,
      freshness: freshness,
      health: health,
      race_signature: race_signature
    }
  end

  defp resolve_member(member, fact_index, {entries, retained, stale?, freshness}) do
    key = member_key(member)

    case Map.fetch(fact_index, key) do
      {:ok, fact} -> current_fact(fact, key, entries, retained, stale?, freshness)
      :error -> retained_fact(member, Map.get(retained, key), key, entries, retained, stale?, freshness)
    end
  end

  defp current_fact(fact, key, entries, retained, stale?, freshness) do
    if valid_complexity?(Map.get(fact, :complexity)) do
      {[fact | entries], Map.put(retained, key, fact), stale?, Map.put(freshness, key, :fresh)}
    else
      {[fact | entries], Map.delete(retained, key), stale?, freshness}
    end
  end

  defp retained_fact(%{terminal?: true}, fact, key, entries, retained, stale?, freshness) when is_map(fact),
    do: {[fact | entries], retained, stale?, Map.put(freshness, key, :fresh)}

  # A replaced member has been superseded by another ticket: the status
  # pipeline will never emit a fact for it again. Serving its retained fact
  # (or none) is the complete truth, not staleness — without this, one
  # replaced member with no fact marks the entire run's weight facts stale
  # forever, which degrades health/ETA to "unhealthy weight facts" while
  # every live ticket's facts are actually current.
  defp retained_fact(%{lifecycle: :replaced}, fact, key, entries, retained, stale?, freshness) when is_map(fact),
    do: {[fact | entries], retained, stale?, Map.put(freshness, key, :fresh)}

  defp retained_fact(%{lifecycle: :replaced}, nil, _key, entries, retained, stale?, freshness),
    do: {entries, retained, stale?, freshness}

  defp retained_fact(_member, fact, key, entries, retained, _stale?, freshness) when is_map(fact),
    do: {[fact | entries], retained, true, Map.put(freshness, key, :stale)}

  defp retained_fact(_member, nil, _key, entries, retained, _stale?, freshness),
    do: {entries, retained, true, freshness}

  defp retain_members(retained, members) do
    keys = members |> Enum.map(&member_key/1) |> Enum.reject(&is_nil/1)
    Map.take(retained, keys)
  end

  defp fact_index(_facts, %{status_facts: false}), do: %{}
  defp fact_index(facts, _availability), do: identity_index(facts)

  defp health(%{status: false}, _stale?, _race?), do: :unavailable
  defp health(%{status_facts: false}, _stale?, _race?), do: :unavailable
  defp health(_availability, true, _race?), do: :stale
  defp health(_availability, _stale?, true), do: :stale
  defp health(_availability, _stale?, _race?), do: :healthy

  defp race_signature(_members, _status, _facts, %{status: false}), do: nil
  defp race_signature(_members, _status, _facts, %{status_facts: false}), do: nil

  defp race_signature(members, status, facts, _availability) do
    # Replaced members are excluded alongside terminal ones: neither can
    # appear in a status bucket again, so counting them as active turns a
    # legitimately absent status/fact row into a permanent race signature.
    active_keys =
      members
      |> Enum.reject(&(Map.get(&1, :terminal?) == true or Map.get(&1, :lifecycle) == :replaced))
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

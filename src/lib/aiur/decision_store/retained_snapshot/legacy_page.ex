defmodule Aiur.DecisionStore.RetainedSnapshot.LegacyPage do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionStore.RetainedSnapshot.QueryPlan

  @spec run(%{String.t() => Decision.t()}, map(), map(), non_neg_integer()) :: map()
  def run(current, index, query, offset) do
    %{candidate: candidate, matcher: matcher, total: total} = QueryPlan.build(index, query)
    snapshot = collect(:gb_sets.iterator(candidate), current, matcher, offset, query.limit, empty_snapshot())

    %{
      decisions: snapshot.page |> Enum.reverse() |> Enum.take(query.limit),
      next_key: continuation_key(snapshot),
      has_next?: has_next?(snapshot, query.limit),
      total: total_for(total, snapshot, offset),
      partial?: false,
      partial_reason: nil
    }
  end

  defp collect(_iterator, _current, _matcher, _offset, limit, %{page_size: page_size} = snapshot)
       when page_size > limit,
       do: snapshot

  defp collect(iterator, current, matcher, offset, limit, snapshot) do
    case :gb_sets.next(iterator) do
      {key, next_iterator} ->
        decision = Map.fetch!(current, decision_id(key))
        snapshot = add_candidate(snapshot, decision, key, matcher, offset, limit)
        collect(next_iterator, current, matcher, offset, limit, snapshot)

      :none ->
        %{snapshot | exhausted?: true}
    end
  end

  defp add_candidate(snapshot, decision, key, matcher, offset, limit) do
    snapshot = %{snapshot | reads: snapshot.reads + 1}

    if matcher.(decision) do
      snapshot
      |> Map.update!(:matches, &(&1 + 1))
      |> skip_or_add(decision, key, offset, limit)
    else
      snapshot
    end
  end

  defp skip_or_add(%{skipped: skipped} = snapshot, _decision, _key, offset, _limit) when skipped < offset,
    do: %{snapshot | skipped: skipped + 1}

  defp skip_or_add(snapshot, decision, key, _offset, limit) do
    page_size = snapshot.page_size + 1

    %{
      snapshot
      | page: [decision | snapshot.page],
        page_size: page_size,
        last_key: if(page_size <= limit, do: key, else: snapshot.last_key)
    }
  end

  defp empty_snapshot do
    %{
      page: [],
      page_size: 0,
      matches: 0,
      skipped: 0,
      reads: 0,
      last_key: nil,
      exhausted?: false
    }
  end

  defp total_for(nil, %{exhausted?: true, matches: matches}, _offset), do: matches
  defp total_for(nil, _snapshot, _offset), do: nil
  defp total_for(total, _snapshot, _offset), do: total
  defp continuation_key(%{last_key: key}), do: key
  defp has_next?(%{page_size: page_size}, limit), do: page_size > limit
  defp decision_id({_created_at, decision_id}), do: decision_id
end

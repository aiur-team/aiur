defmodule Aiur.DecisionStore.RetainedSnapshot.Query do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionStore.RetainedSnapshot.QueryPlan

  @spec run(%{String.t() => Decision.t()}, map(), map()) :: map()
  def run(current, index, query) do
    %{candidate: candidate, matcher: matcher, max_reads: max_reads, total: total} = QueryPlan.build(index, query)
    snapshot = collect(candidate, current, query, matcher, max_reads, empty_snapshot())

    %{
      decisions: snapshot.page |> Enum.reverse() |> Enum.take(query.limit),
      next_key: continuation_key(snapshot),
      has_next?: has_next?(snapshot, query.limit),
      total: total_for(total, snapshot, query),
      partial?: snapshot.capped?,
      partial_reason: if(snapshot.capped?, do: :retained_query_scan_capped)
    }
  end

  defp collect(candidate, current, query, matcher, max_reads, snapshot) do
    iterator = :gb_sets.iterator_from(cursor_key(query.cursor), candidate)
    collect(iterator, iterator_state(current, query, matcher, max_reads, snapshot))
  end

  defp iterator_state(current, query, matcher, max_reads, snapshot) do
    %{current: current, query: query, matcher: matcher, max_reads: max_reads, snapshot: snapshot}
  end

  defp collect(_iterator, %{query: %{limit: limit}, snapshot: %{page_size: page_size} = snapshot})
       when page_size > limit,
       do: snapshot

  defp collect(iterator, %{max_reads: max_reads, snapshot: %{reads: reads} = snapshot})
       when reads >= max_reads and max_reads != :infinity,
       do: capped_or_exhausted(iterator, snapshot)

  defp collect(iterator, state) do
    case :gb_sets.next(iterator) do
      {key, next_iterator} ->
        decision = Map.fetch!(state.current, decision_id(key))
        snapshot = add_candidate(state.snapshot, decision, key, state.query, state.matcher)
        collect(next_iterator, %{state | snapshot: snapshot})

      :none ->
        %{state.snapshot | exhausted?: true}
    end
  end

  defp add_candidate(snapshot, decision, key, query, matcher) do
    snapshot = %{snapshot | reads: snapshot.reads + 1, last_scanned_key: key}

    if after_cursor?(key, query.cursor) and matcher.(decision) do
      page_size = snapshot.page_size + 1

      %{
        snapshot
        | page: [decision | snapshot.page],
          page_size: page_size,
          matches: snapshot.matches + 1,
          last_key: if(page_size <= query.limit, do: key, else: snapshot.last_key)
      }
    else
      snapshot
    end
  end

  defp empty_snapshot do
    %{
      page: [],
      page_size: 0,
      matches: 0,
      reads: 0,
      last_scanned_key: nil,
      last_key: nil,
      capped?: false,
      exhausted?: false
    }
  end

  defp capped_or_exhausted(iterator, snapshot) do
    case :gb_sets.next(iterator) do
      :none -> %{snapshot | exhausted?: true}
      {_key, _next_iterator} -> %{snapshot | capped?: true}
    end
  end

  defp total_for(nil, %{exhausted?: true, matches: matches}, %{cursor: nil}), do: matches
  defp total_for(nil, _snapshot, _query), do: nil
  defp total_for(total, _snapshot, _query), do: total
  defp continuation_key(%{capped?: true, last_scanned_key: key}), do: key
  defp continuation_key(%{last_key: key}), do: key
  defp has_next?(%{capped?: true}, _limit), do: true
  defp has_next?(%{page_size: page_size}, limit), do: page_size > limit
  defp cursor_key(nil), do: {-9_223_372_036_854_775_808, ""}
  defp cursor_key(cursor), do: sort_key(cursor)
  defp after_cursor?(_key, nil), do: true
  defp after_cursor?(key, cursor), do: key > sort_key(cursor)
  defp sort_key(%{created_at: %DateTime{} = created_at, decision_id: decision_id}), do: {-DateTime.to_unix(created_at, :microsecond), decision_id}
  defp decision_id({_created_at, decision_id}), do: decision_id
end

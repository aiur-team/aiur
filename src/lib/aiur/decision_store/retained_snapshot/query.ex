defmodule Aiur.DecisionStore.RetainedSnapshot.Query do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionStore.RetainedIndex

  @lifecycle_statuses [:open, :decided, :acknowledged, :resolved]
  @maximum_candidate_reads 1_000

  @spec run(%{String.t() => Decision.t()}, map(), map()) :: map()
  def run(current, index, query) do
    %{candidate: candidate, matcher: matcher, max_reads: max_reads, total: total} = plan(index, query)
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

  defp plan(index, query) do
    candidate = candidate(index, query)

    %{
      candidate: candidate,
      matcher: &query_match?(&1, query),
      max_reads: if(scan_limited?(query), do: @maximum_candidate_reads, else: :infinity),
      total: if(scan_limited?(query), do: nil, else: :gb_sets.size(candidate))
    }
  end

  defp candidate(index, %{ticket: ticket} = query) when is_binary(ticket),
    do: RetainedIndex.ticket(index, ticket, ordering(query))

  defp candidate(index, %{search: search} = query) when is_binary(search),
    do: RetainedIndex.search(index, search, ordering(query))

  defp candidate(index, %{lifecycle: lifecycle} = query) when lifecycle in @lifecycle_statuses,
    do: RetainedIndex.lifecycle(index, lifecycle, ordering(query))

  defp candidate(index, query), do: RetainedIndex.all(index, ordering(query))

  defp scan_limited?(query) do
    Enum.any?([:ticket, :search, :authority, :blocking, :kind], &(not is_nil(Map.get(query, &1))))
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

  defp query_match?(decision, query) do
    lifecycle_match?(decision, Map.get(query, :lifecycle)) and
      ticket_match?(decision, Map.get(query, :ticket)) and
      search_match?(decision, Map.get(query, :search)) and
      optional_match?(decision.authority, Map.get(query, :authority)) and
      optional_match?(decision.blocking, Map.get(query, :blocking)) and
      kind_match?(decision.kind, Map.get(query, :kind))
  end

  defp ticket_match?(_decision, nil), do: true
  defp ticket_match?(decision, ticket), do: exact_match?(ticket_identifier(decision), ticket)
  defp search_match?(_decision, nil), do: true

  defp search_match?(decision, search) do
    starts_with?(decision.decision_id, search) or starts_with?(ticket_identifier(decision), search)
  end

  defp optional_match?(_actual, nil), do: true
  defp optional_match?(actual, expected), do: actual == expected
  defp kind_match?(_actual, nil), do: true
  defp kind_match?(nil, _expected), do: false
  defp kind_match?(actual, expected), do: String.downcase(String.trim(actual)) == expected
  defp lifecycle_match?(_decision, nil), do: true
  defp lifecycle_match?(decision, lifecycle), do: decision.decision_status == lifecycle
  defp starts_with?(nil, _prefix), do: false
  defp starts_with?(value, prefix), do: String.starts_with?(String.downcase(value), String.downcase(prefix))
  defp exact_match?(nil, _expected), do: false
  defp exact_match?(value, expected), do: String.downcase(value) == String.downcase(expected)
  defp ticket_identifier(%Decision{ticket: ticket}), do: ticket && Map.get(ticket, :identifier)
  defp ordering(query), do: Map.get(query, :ordering, :audit)

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

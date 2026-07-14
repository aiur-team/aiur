defmodule Aiur.DecisionStore.RetainedSnapshot do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionStore.RetainedIndex

  @lifecycle_statuses [:open, :decided, :acknowledged, :resolved]
  @maximum_candidate_reads 1_000

  @type query :: %{
          required(:limit) => pos_integer(),
          required(:cursor) => %{created_at: DateTime.t(), decision_id: String.t()} | nil,
          required(:lifecycle) => Decision.decision_status() | nil,
          required(:search) => String.t() | nil,
          required(:ticket) => String.t() | nil
        }

  @spec build_index(%{String.t() => Decision.t()}, %{optional(String.t()) => [Decision.t()]}) :: map()
  def build_index(current, histories \\ %{}), do: RetainedIndex.build(current, histories)

  @spec update_index(map(), Decision.t() | nil, Decision.t()) :: map()
  def update_index(index, prior, decision), do: RetainedIndex.update(index, prior, decision)

  @spec lookup(%{String.t() => Decision.t()}, term(), String.t()) ::
          {:ok, %{decision: Decision.t() | nil, health: term()}} | {:error, :store_unavailable}
  def lookup(current, health, decision_id) when is_map(current) and is_binary(decision_id) do
    if readable?(health) do
      {:ok, %{decision: Map.get(current, decision_id), health: health}}
    else
      {:error, :store_unavailable}
    end
  end

  @spec query(%{String.t() => Decision.t()}, map(), term(), query()) ::
          {:ok, map()} | {:error, :store_unavailable | :invalid_query}
  def query(current, index, health, %{limit: limit} = query)
      when is_map(current) and is_map(index) and is_integer(limit) and limit > 0 do
    cond do
      not valid_query?(query) -> {:error, :invalid_query}
      not readable?(health) -> {:error, :store_unavailable}
      true -> query_snapshot(current, index, health, query)
    end
  end

  def query(_current, _index, _health, _query), do: {:error, :invalid_query}

  @spec counts(map(), term()) :: {:ok, %{counts: map(), health: term()}} | {:error, :store_unavailable}
  def counts(index, health) when is_map(index) do
    if readable?(health) do
      {:ok, %{counts: RetainedIndex.canonical_counts(index), health: health}}
    else
      {:error, :store_unavailable}
    end
  end

  def counts(_index, _health), do: {:error, :store_unavailable}

  defp query_snapshot(current, index, health, query) do
    %{candidate: candidate, matcher: matcher, max_reads: max_reads, total: total} = query_plan(index, query)
    snapshot = collect(candidate, current, query, matcher, max_reads)

    {:ok,
     %{
       decisions: snapshot.page |> Enum.reverse() |> Enum.take(query.limit),
       next_key: continuation_key(snapshot),
       has_next?: has_next?(snapshot, query.limit),
       total: total_for(total, snapshot, query),
       partial?: snapshot.capped?,
       counts: RetainedIndex.canonical_counts(index),
       health: health
     }}
  end

  defp query_plan(index, %{ticket: ticket, lifecycle: lifecycle}) when is_binary(ticket) do
    %{
      candidate: RetainedIndex.ticket(index, ticket),
      matcher: &ticket_match?(&1, ticket, lifecycle),
      max_reads: @maximum_candidate_reads,
      total: nil
    }
  end

  defp query_plan(index, %{search: search, lifecycle: lifecycle}) when is_binary(search) do
    %{
      candidate: RetainedIndex.search(index, search),
      matcher: &search_match?(&1, search, lifecycle),
      max_reads: @maximum_candidate_reads,
      total: nil
    }
  end

  defp query_plan(index, %{lifecycle: nil}) do
    %{
      candidate: RetainedIndex.all(index),
      matcher: fn _ -> true end,
      max_reads: :infinity,
      total: :gb_sets.size(RetainedIndex.all(index))
    }
  end

  defp query_plan(index, %{lifecycle: lifecycle}) do
    candidate = RetainedIndex.lifecycle(index, lifecycle)
    %{candidate: candidate, matcher: fn _ -> true end, max_reads: :infinity, total: :gb_sets.size(candidate)}
  end

  defp collect(candidate, current, query, matcher, max_reads) do
    iterator = :gb_sets.iterator_from(cursor_key(query.cursor), candidate)
    collect(iterator, current, query, matcher, max_reads, empty_snapshot())
  end

  defp collect(
         _iterator,
         _current,
         %{limit: limit},
         _matcher,
         _max_reads,
         %{page_size: page_size} = snapshot
       )
       when page_size > limit,
       do: snapshot

  defp collect(
         iterator,
         _current,
         _query,
         _matcher,
         max_reads,
         %{reads: reads} = snapshot
       )
       when reads >= max_reads and max_reads != :infinity,
       do: capped_or_exhausted(iterator, snapshot)

  defp collect(iterator, current, query, matcher, max_reads, snapshot) do
    case :gb_sets.next(iterator) do
      {key, next_iterator} ->
        decision = Map.fetch!(current, decision_id(key))
        snapshot = %{snapshot | reads: snapshot.reads + 1}

        snapshot =
          if after_cursor?(key, query.cursor) and matcher.(decision) do
            page_size = snapshot.page_size + 1

            %{
              snapshot
              | page: [decision | snapshot.page],
                page_size: page_size,
                matches: snapshot.matches + 1,
                last_scanned_key: key,
                last_key: if(page_size <= query.limit, do: key, else: snapshot.last_key)
            }
          else
            %{snapshot | last_scanned_key: key}
          end

        collect(next_iterator, current, query, matcher, max_reads, snapshot)

      :none ->
        %{snapshot | exhausted?: true}
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

  defp ticket_match?(decision, ticket, lifecycle) do
    lifecycle_match?(decision, lifecycle) and starts_with?(ticket_identifier(decision), ticket)
  end

  defp search_match?(decision, search, lifecycle) do
    lifecycle_match?(decision, lifecycle) and
      (starts_with?(decision.decision_id, search) or starts_with?(ticket_identifier(decision), search))
  end

  defp lifecycle_match?(_decision, nil), do: true
  defp lifecycle_match?(decision, lifecycle), do: decision.decision_status == lifecycle
  defp starts_with?(nil, _prefix), do: false
  defp starts_with?(value, prefix), do: String.starts_with?(String.downcase(value), String.downcase(prefix))
  defp ticket_identifier(%Decision{ticket: ticket}), do: ticket && Map.get(ticket, :identifier)

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

  defp sort_key(%Decision{} = decision) do
    {-DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
  end

  defp sort_key(%{created_at: %DateTime{} = created_at, decision_id: decision_id})
       when is_binary(decision_id) do
    {-DateTime.to_unix(created_at, :microsecond), decision_id}
  end

  defp decision_id({_created_at, decision_id}), do: decision_id

  defp readable?(:writable), do: true
  defp readable?({:corrupt, _line, _reason}), do: true
  defp readable?(_health), do: false

  defp valid_query?(%{cursor: cursor, lifecycle: lifecycle, search: search, ticket: ticket}) do
    valid_cursor?(cursor) and
      (is_nil(lifecycle) or lifecycle in @lifecycle_statuses) and
      valid_optional_string?(search) and
      valid_optional_string?(ticket) and
      (is_nil(search) or is_nil(ticket))
  end

  defp valid_query?(_query), do: false
  defp valid_cursor?(nil), do: true
  defp valid_cursor?(%{created_at: %DateTime{}, decision_id: decision_id}) when is_binary(decision_id), do: true
  defp valid_cursor?(_cursor), do: false
  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: is_binary(value) and String.valid?(value)
end

defmodule Aiur.DecisionStore.RetainedSnapshot do
  @moduledoc false

  alias Aiur.Decision

  @type query :: %{
          required(:limit) => pos_integer(),
          required(:cursor) => %{created_at: DateTime.t(), decision_id: String.t()} | nil,
          required(:lifecycle) => Decision.decision_status() | nil,
          required(:search) => String.t() | nil,
          required(:ticket) => String.t() | nil
        }

  @spec build_index(%{String.t() => Decision.t()}) :: :gb_sets.set()
  def build_index(current) do
    current
    |> Map.values()
    |> Enum.map(&sort_key/1)
    |> :gb_sets.from_list()
  end

  @spec update_index(:gb_sets.set(), Decision.t() | nil, Decision.t()) :: :gb_sets.set()
  def update_index(index, prior, %Decision{} = decision) do
    index
    |> delete_from_index(prior)
    |> then(&:gb_sets.add(sort_key(decision), &1))
  end

  @spec lookup(%{String.t() => Decision.t()}, term(), String.t()) ::
          {:ok, %{decision: Decision.t() | nil, health: term()}} | {:error, :store_unavailable}
  def lookup(current, health, decision_id) when is_map(current) and is_binary(decision_id) do
    if readable?(health),
      do: {:ok, %{decision: Map.get(current, decision_id), health: health}},
      else: {:error, :store_unavailable}
  end

  @spec query(%{String.t() => Decision.t()}, :gb_sets.set(), term(), query()) ::
          {:ok, map()} | {:error, :store_unavailable | :invalid_query}
  def query(current, index, health, %{limit: limit} = query)
      when is_map(current) and is_integer(limit) and limit > 0 do
    cond do
      not valid_query?(query) ->
        {:error, :invalid_query}

      not readable?(health) ->
        {:error, :store_unavailable}

      true ->
        snapshot = collect(:gb_sets.iterator(index), current, query, empty_snapshot())

        {:ok,
         %{
           decisions: Enum.reverse(snapshot.page) |> Enum.take(limit),
           has_next?: snapshot.page_size > limit,
           total: snapshot.total,
           counts: snapshot.counts,
           health: health
         }}
    end
  end

  def query(_current, _index, _health, _query), do: {:error, :invalid_query}

  @spec counts(%{String.t() => Decision.t()}, term()) ::
          {:ok, %{open: non_neg_integer(), blocking: non_neg_integer(), health: term()}} | {:error, :store_unavailable}
  def counts(current, health) when is_map(current) do
    if readable?(health) do
      {:ok, %{counts: counts_for(Map.values(current)), health: health}}
    else
      {:error, :store_unavailable}
    end
  end

  defp collect(iterator, current, query, snapshot) do
    case :gb_sets.next(iterator) do
      {key, next_iterator} ->
        decision = Map.fetch!(current, decision_id(key))
        snapshot = update_snapshot(snapshot, decision, query)
        collect(next_iterator, current, query, snapshot)

      :none ->
        snapshot
    end
  end

  defp update_snapshot(snapshot, decision, query) do
    counts = update_counts(snapshot.counts, decision)

    if matches?(decision, query) do
      snapshot = %{snapshot | counts: counts, total: snapshot.total + 1}

      if after_cursor?(decision, query.cursor) and snapshot.page_size <= query.limit do
        %{snapshot | page: [decision | snapshot.page], page_size: snapshot.page_size + 1}
      else
        snapshot
      end
    else
      %{snapshot | counts: counts}
    end
  end

  defp empty_snapshot, do: %{page: [], page_size: 0, total: 0, counts: %{open: 0, blocking: 0}}

  defp counts_for(decisions), do: Enum.reduce(decisions, %{open: 0, blocking: 0}, &update_counts(&2, &1))

  defp update_counts(counts, %Decision{decision_status: :open, blocking: blocking}) do
    %{counts | open: counts.open + 1, blocking: counts.blocking + if(blocking, do: 1, else: 0)}
  end

  defp update_counts(counts, %Decision{}), do: counts

  defp matches?(%Decision{} = decision, query) do
    lifecycle_matches?(decision, query.lifecycle) and
      optional_match(query.ticket, decision.ticket.identifier) and
      search_matches?(decision, query.search)
  end

  defp lifecycle_matches?(_decision, nil), do: true
  defp lifecycle_matches?(decision, lifecycle), do: decision.decision_status == lifecycle

  defp optional_match(nil, _actual), do: true
  defp optional_match(expected, actual) when is_binary(actual), do: String.contains?(String.downcase(actual), String.downcase(expected))
  defp optional_match(_expected, _actual), do: false

  defp search_matches?(_decision, nil), do: true

  defp search_matches?(decision, search) do
    needle = String.downcase(search)
    String.contains?(String.downcase(decision.decision_id), needle) or optional_match(search, decision.ticket.identifier)
  end

  defp after_cursor?(_decision, nil), do: true
  defp after_cursor?(decision, cursor), do: audit_key(decision) < audit_key(cursor)

  defp sort_key(%Decision{} = decision) do
    {-DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
  end

  defp audit_key(%Decision{} = decision), do: {DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
  defp audit_key(cursor), do: {DateTime.to_unix(cursor.created_at, :microsecond), cursor.decision_id}
  defp decision_id({_created_at, decision_id}), do: decision_id

  defp delete_from_index(index, %Decision{} = decision), do: :gb_sets.delete_any(sort_key(decision), index)
  defp delete_from_index(index, _prior), do: index

  defp readable?(:writable), do: true
  defp readable?({:corrupt, _line, _reason}), do: true
  defp readable?(_health), do: false

  defp valid_query?(%{cursor: cursor, lifecycle: lifecycle, search: search, ticket: ticket}) do
    valid_cursor?(cursor) and
      (is_nil(lifecycle) or lifecycle in [:open, :decided, :acknowledged, :resolved]) and
      valid_optional_string?(search) and
      valid_optional_string?(ticket)
  end

  defp valid_query?(_query), do: false

  defp valid_cursor?(nil), do: true

  defp valid_cursor?(%{created_at: %DateTime{}, decision_id: decision_id}) when is_binary(decision_id), do: true
  defp valid_cursor?(_cursor), do: false

  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: is_binary(value) and String.valid?(value)
end

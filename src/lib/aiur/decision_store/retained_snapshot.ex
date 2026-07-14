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

  @lifecycle_statuses [:open, :decided, :acknowledged, :resolved]
  @maximum_prefix_length 200

  @spec build_index(%{String.t() => Decision.t()}) :: map()
  def build_index(current) do
    Enum.reduce(current, empty_index(), fn {_decision_id, decision}, index ->
      add_to_index(index, decision)
    end)
  end

  @spec update_index(map(), Decision.t() | nil, Decision.t()) :: map()
  def update_index(index, prior, %Decision{} = decision) do
    index
    |> remove_from_index(prior)
    |> add_to_index(decision)
  end

  @spec lookup(%{String.t() => Decision.t()}, term(), String.t()) ::
          {:ok, %{decision: Decision.t() | nil, health: term()}} | {:error, :store_unavailable}
  def lookup(current, health, decision_id) when is_map(current) and is_binary(decision_id) do
    if readable?(health),
      do: {:ok, %{decision: Map.get(current, decision_id), health: health}},
      else: {:error, :store_unavailable}
  end

  @spec query(%{String.t() => Decision.t()}, map(), term(), query()) ::
          {:ok, map()} | {:error, :store_unavailable | :invalid_query}
  def query(current, index, health, %{limit: limit} = query)
      when is_map(current) and is_map(index) and is_integer(limit) and limit > 0 do
    cond do
      not valid_query?(query) ->
        {:error, :invalid_query}

      not readable?(health) ->
        {:error, :store_unavailable}

      true ->
        candidate_index = index_for(index, query)
        snapshot = collect(iterator_after(candidate_index, query.cursor), current, limit, query.cursor, empty_snapshot())

        {:ok,
         %{
           decisions: Enum.reverse(snapshot.page) |> Enum.take(limit),
           has_next?: snapshot.page_size > limit,
           total: :gb_sets.size(candidate_index),
           counts: canonical_counts(index),
           health: health
         }}
    end
  end

  def query(_current, _index, _health, _query), do: {:error, :invalid_query}

  @spec counts(map(), term()) :: {:ok, %{counts: map(), health: term()}} | {:error, :store_unavailable}
  def counts(index, health) when is_map(index) do
    if readable?(health),
      do: {:ok, %{counts: canonical_counts(index), health: health}},
      else: {:error, :store_unavailable}
  end

  def counts(_index, _health), do: {:error, :store_unavailable}

  defp collect(_iterator, _current, limit, _cursor, snapshot) when snapshot.page_size > limit, do: snapshot

  defp collect(iterator, current, limit, cursor, snapshot) do
    case :gb_sets.next(iterator) do
      {key, next_iterator} ->
        decision = Map.fetch!(current, decision_id(key))

        snapshot =
          if after_cursor?(decision, cursor) do
            %{snapshot | page: [decision | snapshot.page], page_size: snapshot.page_size + 1}
          else
            snapshot
          end

        collect(next_iterator, current, limit, cursor, snapshot)

      :none ->
        snapshot
    end
  end

  defp empty_snapshot, do: %{page: [], page_size: 0}

  defp empty_index do
    lifecycle = Map.new(@lifecycle_statuses, &{&1, :gb_sets.empty()})
    %{all: :gb_sets.empty(), lifecycle: lifecycle, tickets: %{}, searches: %{}, counts: %{open: 0, blocking: 0}}
  end

  defp add_to_index(index, %Decision{} = decision) do
    key = sort_key(decision)
    ticket_prefixes = ticket_prefixes(decision)
    search_prefixes = search_prefixes(decision, ticket_prefixes)

    %{
      index
      | all: :gb_sets.add(key, index.all),
        lifecycle: Map.update!(index.lifecycle, decision.decision_status, &:gb_sets.add(key, &1)),
        tickets: add_prefixes(index.tickets, ticket_prefixes, decision.decision_status, key),
        searches: add_prefixes(index.searches, search_prefixes, decision.decision_status, key),
        counts: increment_counts(index.counts, decision)
    }
  end

  defp remove_from_index(index, %Decision{} = decision) do
    key = sort_key(decision)
    ticket_prefixes = ticket_prefixes(decision)
    search_prefixes = search_prefixes(decision, ticket_prefixes)

    %{
      index
      | all: :gb_sets.delete_any(key, index.all),
        lifecycle: Map.update!(index.lifecycle, decision.decision_status, &:gb_sets.delete_any(key, &1)),
        tickets: remove_prefixes(index.tickets, ticket_prefixes, decision.decision_status, key),
        searches: remove_prefixes(index.searches, search_prefixes, decision.decision_status, key),
        counts: decrement_counts(index.counts, decision)
    }
  end

  defp remove_from_index(index, _prior), do: index

  defp add_prefixes(index, prefixes, lifecycle, key) do
    Enum.reduce(prefixes, index, fn prefix, index ->
      Enum.reduce([nil, lifecycle], index, fn scope, index ->
        Map.update(index, {scope, prefix}, :gb_sets.add(key, :gb_sets.empty()), &:gb_sets.add(key, &1))
      end)
    end)
  end

  defp remove_prefixes(index, prefixes, lifecycle, key) do
    Enum.reduce(prefixes, index, fn prefix, index ->
      Enum.reduce([nil, lifecycle], index, fn scope, index ->
        Map.update(index, {scope, prefix}, :gb_sets.empty(), &:gb_sets.delete_any(key, &1))
      end)
    end)
  end

  defp increment_counts(counts, %Decision{decision_status: :open, blocking: blocking}) do
    %{counts | open: counts.open + 1, blocking: counts.blocking + if(blocking, do: 1, else: 0)}
  end

  defp increment_counts(counts, %Decision{}), do: counts

  defp decrement_counts(counts, %Decision{decision_status: :open, blocking: blocking}) do
    %{counts | open: counts.open - 1, blocking: counts.blocking - if(blocking, do: 1, else: 0)}
  end

  defp decrement_counts(counts, %Decision{}), do: counts

  defp canonical_counts(index), do: Map.put(index.counts, :total, :gb_sets.size(index.all))

  defp iterator_after(index, nil), do: :gb_sets.iterator(index)
  defp iterator_after(index, cursor), do: :gb_sets.iterator_from(sort_key(cursor), index)

  defp after_cursor?(_decision, nil), do: true
  defp after_cursor?(decision, cursor), do: sort_key(decision) > sort_key(cursor)

  defp index_for(index, %{ticket: nil, search: nil, lifecycle: nil}), do: index.all
  defp index_for(index, %{ticket: nil, search: nil, lifecycle: lifecycle}), do: Map.fetch!(index.lifecycle, lifecycle)
  defp index_for(index, %{ticket: ticket, search: nil, lifecycle: lifecycle}), do: prefix_index(index.tickets, lifecycle, ticket)
  defp index_for(index, %{ticket: nil, search: search, lifecycle: lifecycle}), do: prefix_index(index.searches, lifecycle, search)

  defp prefix_index(index, lifecycle, value) do
    Map.get(index, {lifecycle, String.downcase(value)}, :gb_sets.empty())
  end

  defp ticket_prefixes(%Decision{ticket: ticket}), do: prefixes(ticket && Map.get(ticket, :identifier))

  defp search_prefixes(decision, ticket_prefixes) do
    prefixes(decision.decision_id)
    |> Kernel.++(ticket_prefixes)
    |> Enum.uniq()
  end

  defp prefixes(value) when is_binary(value) do
    value = String.downcase(value)
    length = min(String.length(value), @maximum_prefix_length)

    if length == 0, do: [], else: Enum.map(1..length, &String.slice(value, 0, &1))
  end

  defp prefixes(_value), do: []

  defp sort_key(%Decision{} = decision) do
    {-DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
  end

  defp sort_key(%{created_at: %DateTime{} = created_at, decision_id: decision_id}) when is_binary(decision_id) do
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

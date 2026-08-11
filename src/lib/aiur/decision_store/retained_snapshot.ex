defmodule Aiur.DecisionStore.RetainedSnapshot do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionStore.RetainedIndex
  alias Aiur.DecisionStore.RetainedSnapshot.{LegacyPage, Query}

  @lifecycle_statuses [
    :open,
    :awaiting,
    :deferred,
    :historic,
    :history,
    :expired,
    :dismissed,
    :decided,
    :acknowledged,
    :resolved
  ]

  @type query :: %{
          required(:limit) => pos_integer(),
          required(:cursor) => %{created_at: DateTime.t(), decision_id: String.t()} | nil,
          optional(:authority) => Decision.authority() | nil,
          optional(:blocking) => boolean() | nil,
          optional(:kind) => String.t() | nil,
          optional(:ordering) => :audit | :current,
          required(:lifecycle) => Decision.decision_status() | :awaiting | :historic | :history | nil,
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

  @spec legacy_page(%{String.t() => Decision.t()}, map(), term(), query(), non_neg_integer()) ::
          {:ok, map()} | {:error, :store_unavailable | :invalid_query}
  def legacy_page(current, index, health, %{limit: limit} = query, offset)
      when is_map(current) and is_map(index) and is_integer(limit) and limit > 0 and
             is_integer(offset) and offset >= 0 do
    cond do
      not valid_query?(query) -> {:error, :invalid_query}
      not readable?(health) -> {:error, :store_unavailable}
      true -> legacy_snapshot(current, index, health, query, offset)
    end
  end

  def legacy_page(_current, _index, _health, _query, _offset), do: {:error, :invalid_query}

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
    snapshot = Query.run(current, index, query)

    {:ok,
     %{
       decisions: snapshot.decisions,
       next_key: snapshot.next_key,
       has_next?: snapshot.has_next?,
       total: snapshot.total,
       partial?: snapshot.partial?,
       partial_reason: snapshot.partial_reason,
       counts: RetainedIndex.canonical_counts(index),
       health: health
     }}
  end

  defp legacy_snapshot(current, index, health, query, offset) do
    snapshot = LegacyPage.run(current, index, query, offset)

    {:ok,
     %{
       decisions: snapshot.decisions,
       next_key: snapshot.next_key,
       has_next?: snapshot.has_next?,
       total: snapshot.total,
       partial?: snapshot.partial?,
       partial_reason: snapshot.partial_reason,
       counts: RetainedIndex.canonical_counts(index),
       health: health
     }}
  end

  defp readable?(:writable), do: true
  defp readable?({:corrupt, _line, _reason}), do: true
  defp readable?(_health), do: false

  defp valid_query?(%{cursor: cursor, lifecycle: lifecycle, search: search, ticket: ticket} = query) do
    [
      valid_cursor?(cursor),
      valid_lifecycle?(lifecycle),
      valid_optional_authority?(Map.get(query, :authority)),
      valid_optional_boolean?(Map.get(query, :blocking)),
      valid_optional_string?(Map.get(query, :kind)),
      valid_optional_string?(search),
      valid_optional_string?(ticket),
      valid_search_ticket?(search, ticket),
      valid_ordering?(Map.get(query, :ordering, :audit))
    ]
    |> Enum.all?()
  end

  defp valid_query?(_query), do: false
  defp valid_cursor?(nil), do: true
  defp valid_cursor?(%{created_at: %DateTime{}, decision_id: decision_id}) when is_binary(decision_id), do: true
  defp valid_cursor?(_cursor), do: false
  defp valid_lifecycle?(nil), do: true
  defp valid_lifecycle?(lifecycle), do: lifecycle in @lifecycle_statuses
  defp valid_optional_authority?(nil), do: true
  defp valid_optional_authority?(authority), do: authority in Decision.authorities()
  defp valid_optional_boolean?(nil), do: true
  defp valid_optional_boolean?(value), do: is_boolean(value)
  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: is_binary(value) and String.valid?(value)
  defp valid_search_ticket?(search, ticket), do: is_nil(search) or is_nil(ticket)
  defp valid_ordering?(ordering), do: ordering in [:audit, :current]
end

defmodule Aiur.DecisionQuery do
  @moduledoc """
  Bounded retained-Decision read contracts.

  This module deliberately reads through `DecisionStore`: its current projection
  remains the persistence authority. The priority overview and retained query
  are different contracts. Retained pages use immutable creation time and
  canonical ID ordering so a lifecycle transition cannot move an item across a
  cursor boundary.
  """

  alias Aiur.DecisionQuery.{Cursor, Params, StoreReader}
  alias Aiur.DecisionStore

  @default_store DecisionStore

  @doc false
  @spec default_store() :: module()
  def default_store, do: @default_store

  @doc "Returns one exact retained Decision without consulting the overview window."
  @spec get(String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :store_unavailable
             | {:indeterminate, map()}
             | {:invalid_decision_id, atom()}}
  def get(decision_id, opts \\ [])

  def get(decision_id, opts) when is_list(opts) do
    with {:ok, normalized_id} <- Params.normalize_decision_id(decision_id),
         {:ok, decision, health} <- StoreReader.read_one(normalized_id, store(opts)) do
      {:ok, %{decision: decision, scope: scope(), health: health}}
    end
  end

  def get(_decision_id, _opts), do: {:error, {:invalid_decision_id, :invalid_type}}

  @doc "Returns one stable, bounded retained-Decision page and its query metadata."
  @spec list(map(), keyword()) :: {:ok, map()} | {:error, {:invalid_query, term()}}
  def list(params \\ %{}, opts \\ [])

  def list(params, opts) when is_map(params) and is_list(opts) do
    with {:ok, query} <- Params.parse(params) do
      query = Map.put(query, :ordering, ordering(opts))

      case StoreReader.read_query(query, store(opts)) do
        {:ok, snapshot, health} -> {:ok, retained_page(snapshot, query, health)}
        {:error, :store_unavailable} -> {:ok, unavailable_page(query)}
      end
    end
  end

  def list(_params, _opts), do: {:error, {:invalid_query, {:params, :invalid_type}}}

  @doc false
  @spec legacy_page(map(), non_neg_integer(), pos_integer(), keyword()) :: {:ok, map()} | {:error, {:invalid_query, term()}}
  def legacy_page(query, offset, limit, opts \\ [])

  def legacy_page(query, offset, limit, opts)
      when is_map(query) and is_integer(offset) and offset >= 0 and is_integer(limit) and limit > 0 and is_list(opts) do
    query = Map.merge(query, %{cursor: nil, limit: limit, ordering: :current})

    case StoreReader.read_legacy_page(query, offset, limit, store(opts)) do
      {:ok, snapshot, health} -> {:ok, retained_page(snapshot, query, health)}
      {:error, :store_unavailable} -> {:ok, unavailable_page(query)}
      {:error, :invalid_query} -> {:error, {:invalid_query, :legacy_page}}
    end
  end

  def legacy_page(_query, _offset, _limit, _opts), do: {:error, {:invalid_query, :legacy_page}}

  @doc "Returns canonical retained open and blocking counts with retention health."
  @spec counts(keyword()) :: {:ok, map()}
  def counts(opts \\ []) when is_list(opts) do
    case StoreReader.read_counts(store(opts)) do
      {:ok, counts, health} ->
        {:ok, Map.merge(counts, %{scope: scope(), health: health})}

      {:error, :store_unavailable} ->
        {:ok, %{open: nil, blocking: nil, total: nil, scope: scope(), health: StoreReader.unavailable_health()}}
    end
  end

  defp store(opts), do: Keyword.get(opts, :store, @default_store)
  defp ordering(opts), do: if(Keyword.get(opts, :ordering) == :current, do: :current, else: :audit)

  defp next_cursor(_key, false), do: nil
  defp next_cursor(nil, true), do: nil

  defp next_cursor({created_at, decision_id}, true) do
    %{created_at: DateTime.from_unix!(-created_at, :microsecond), decision_id: decision_id}
    |> Cursor.encode()
  end

  defp retained_page(snapshot, query, health) do
    partial? = health.partial? or Map.get(snapshot, :partial?, false)
    partial_reason = partial_reason(health, snapshot)

    %{
      decisions: snapshot.decisions,
      scope: scope(),
      health: health,
      partial_results?: partial?,
      partial_reason: partial_reason,
      pagination: %{
        limit: query.limit,
        cursor: query.cursor && Cursor.encode(query.cursor),
        next_cursor: next_cursor(Map.get(snapshot, :next_key), snapshot.has_next?),
        total: snapshot.total,
        partial_reason: partial_reason,
        label: pagination_label(query.limit, snapshot.has_next?, partial_reason)
      },
      filters: Map.take(query, [:authority, :blocking, :kind, :lifecycle, :search, :ticket]),
      counts: snapshot.counts
    }
  end

  defp unavailable_page(query) do
    %{
      decisions: [],
      scope: scope(),
      health: StoreReader.unavailable_health(),
      partial_results?: true,
      partial_reason: :retained_store_unavailable,
      pagination: %{
        limit: query.limit,
        cursor: query.cursor && Cursor.encode(query.cursor),
        next_cursor: nil,
        total: nil,
        partial_reason: :retained_store_unavailable,
        label: "Retained Decision page unavailable"
      },
      filters: Map.take(query, [:authority, :blocking, :kind, :lifecycle, :search, :ticket])
    }
  end

  defp scope, do: %{kind: :retained, label: "All retained decisions"}

  defp partial_reason(%{reason: :retained_store_partial}, _snapshot), do: :retained_store_partial

  defp partial_reason(_health, %{partial_reason: :retained_query_scan_capped}),
    do: :retained_query_scan_capped

  defp partial_reason(_health, _snapshot), do: nil

  defp pagination_label(limit, _has_next?, :retained_store_partial) do
    "Partial retained Decision page of up to #{limit}; retained audit data is corrupt, so refining filters cannot make results complete"
  end

  defp pagination_label(limit, _has_next?, :retained_query_scan_capped) do
    "Partial retained Decision page of up to #{limit}; refine the filter for complete results"
  end

  defp pagination_label(limit, true, nil) do
    "Retained Decision page of up to #{limit}; more results are available"
  end

  defp pagination_label(limit, false, nil), do: "Final retained Decision page of up to #{limit}"
end

defmodule Aiur.DecisionQuery.StoreReader do
  @moduledoc false

  alias Aiur.{Decision, DecisionStore}

  @type health :: %{
          status: :available | :partial | :unavailable,
          partial?: boolean(),
          reason: nil | :retained_store_partial | :retained_store_unavailable,
          label: String.t()
        }

  @spec read_one(String.t(), GenServer.server()) ::
          {:ok, Decision.t(), health()} | {:error, :not_found | :store_unavailable | {:indeterminate, health()}}
  def read_one(decision_id, store) do
    case safe_store_call(fn -> DecisionStore.retained_lookup(decision_id, store) end) do
      {:ok, %{decision: %Decision{} = decision, health: store_health}} -> {:ok, decision, health(store_health)}
      {:ok, %{decision: nil, health: store_health}} -> missing_decision(health(store_health))
      _unavailable -> {:error, :store_unavailable}
    end
  end

  @spec read_query(map(), GenServer.server()) :: {:ok, map(), health()} | {:error, :store_unavailable}
  def read_query(query, store) do
    case safe_store_call(fn -> DecisionStore.retained_query(query, store) end) do
      {:ok, %{decisions: decisions, counts: counts, health: store_health} = snapshot}
      when is_list(decisions) and is_map(counts) ->
        {:ok, Map.drop(snapshot, [:health]), health(store_health)}

      _unavailable ->
        {:error, :store_unavailable}
    end
  end

  @spec read_legacy_page(map(), non_neg_integer(), pos_integer(), GenServer.server()) ::
          {:ok, map(), health()} | {:error, :invalid_query | :store_unavailable}
  def read_legacy_page(query, offset, limit, store) do
    case safe_store_call(fn -> DecisionStore.retained_legacy_page(query, offset, limit, store) end) do
      {:ok, %{decisions: decisions, counts: counts, health: store_health} = snapshot}
      when is_list(decisions) and is_map(counts) ->
        {:ok, Map.drop(snapshot, [:health]), health(store_health)}

      {:error, :invalid_query} ->
        {:error, :invalid_query}

      _unavailable ->
        {:error, :store_unavailable}
    end
  end

  @spec read_counts(GenServer.server()) :: {:ok, map(), health()} | {:error, :store_unavailable}
  def read_counts(store) do
    case safe_store_call(fn -> DecisionStore.retained_counts(store) end) do
      {:ok, %{counts: %{open: open, blocking: blocking} = counts, health: store_health}}
      when is_integer(open) and is_integer(blocking) ->
        {:ok, Map.take(counts, [:open, :blocking, :total]), health(store_health)}

      _unavailable ->
        {:error, :store_unavailable}
    end
  end

  @spec unavailable_health() :: health()
  def unavailable_health do
    %{status: :unavailable, partial?: true, reason: :retained_store_unavailable, label: "Retained Decision data unavailable"}
  end

  defp safe_store_call(fun) do
    fun.()
  rescue
    _error -> :store_unavailable
  catch
    :exit, _reason -> :store_unavailable
  end

  defp available_health do
    %{status: :available, partial?: false, reason: nil, label: "Complete retained Decision data"}
  end

  defp partial_health do
    %{status: :partial, partial?: true, reason: :retained_store_partial, label: "Partial retained Decision data"}
  end

  defp missing_decision(%{status: :partial} = health), do: {:error, {:indeterminate, health}}
  defp missing_decision(_health), do: {:error, :not_found}

  defp health(:writable), do: available_health()
  defp health({:corrupt, _line, _reason}), do: partial_health()
  defp health(_unavailable), do: unavailable_health()
end

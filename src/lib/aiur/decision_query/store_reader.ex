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
          {:ok, Decision.t(), health()} | {:error, :not_found | :store_unavailable}
  def read_one(decision_id, store) do
    with {:ok, health} <- read_health(store),
         result <- safe_store_call(fn -> DecisionStore.get(decision_id, store) end) do
      case result do
        {:ok, %Decision{} = decision} -> {:ok, decision, health}
        {:error, :not_found} when health.status == :available -> {:error, :not_found}
        _other -> {:error, :store_unavailable}
      end
    end
  end

  @spec read_all(GenServer.server()) :: {:ok, [Decision.t()], health()} | {:error, :store_unavailable}
  def read_all(store) do
    with {:ok, health} <- read_health(store),
         decisions when is_list(decisions) <- safe_store_call(fn -> DecisionStore.list(store) end) do
      {:ok, decisions, health}
    else
      _invalid -> {:error, :store_unavailable}
    end
  end

  @spec unavailable_health() :: health()
  def unavailable_health do
    %{status: :unavailable, partial?: true, reason: :retained_store_unavailable, label: "Retained Decision data unavailable"}
  end

  defp read_health(store) do
    case safe_store_call(fn -> DecisionStore.health(store) end) do
      :writable -> {:ok, available_health()}
      {:corrupt, _count, _reason} -> {:ok, partial_health()}
      _unavailable -> {:error, :store_unavailable}
    end
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
end

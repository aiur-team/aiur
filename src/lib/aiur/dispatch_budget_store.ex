defmodule Aiur.DispatchBudgetStore do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @spec lifetime(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def lifetime(issue_id) when is_binary(issue_id) do
    with {:ok, lifetimes} <- read_lifetimes() do
      case Map.get(lifetimes, issue_id, 0) do
        value when is_integer(value) and value >= 0 -> {:ok, value}
        _other -> {:error, :invalid_lifetime}
      end
    end
  end

  @spec put_lifetime(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def put_lifetime(issue_id, lifetime)
      when is_binary(issue_id) and is_integer(lifetime) and lifetime >= 0 do
    case read_lifetimes() do
      {:ok, lifetimes} ->
        JsonStore.write!(path_for(), Map.put(lifetimes, issue_id, lifetime))

      {:error, reason} = error ->
        Logger.error("Dispatch budget store read before write failed: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.error("Dispatch budget store write failed: #{Exception.message(error)}")
      {:error, error}
  end

  @doc false
  @spec path_for() :: Path.t()
  def path_for do
    case Application.get_env(:aiur, :dispatch_budget_store_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        case Paths.decision_state_dir() do
          {:ok, state_dir} -> Path.join(state_dir, "dispatch-budgets.json")
          {:error, reason} -> raise "dispatch budget state path unavailable: #{inspect(reason)}"
        end
    end
  end

  defp read_lifetimes do
    case JsonStore.read(path_for(), %{}) do
      {:ok, %{} = lifetimes} -> {:ok, lifetimes}
      {:ok, _other} -> {:error, :invalid_store}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end
end

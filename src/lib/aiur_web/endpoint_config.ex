defmodule AiurWeb.EndpointConfig do
  @moduledoc """
  Reads `AiurWeb.Endpoint` config through a per-test override seam.

  Tests stub dashboard providers in an override table keyed by the owning test
  process. Only that process and processes naming it in `$callers` (its
  LiveViews and Tasks) see the stub; every other process reads the shared
  endpoint config. Outside tests the table does not exist (#4908).
  """

  @table __MODULE__.Overrides

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) do
    case override(key) do
      {:ok, value} -> value
      :error -> AiurWeb.Endpoint.config(key, default)
    end
  end

  @doc false
  @spec overrides_table() :: atom()
  def overrides_table, do: @table

  defp override(key) do
    case :ets.whereis(@table) do
      :undefined -> :error
      table -> Enum.find_value([self() | Process.get(:"$callers", [])], :error, &lookup(table, &1, key))
    end
  end

  defp lookup(table, owner, key) do
    case :ets.lookup(table, {owner, key}) do
      [{_owner_key, value}] -> {:ok, value}
      [] -> nil
    end
  end
end

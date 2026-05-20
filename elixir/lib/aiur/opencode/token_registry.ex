defmodule Aiur.Opencode.TokenRegistry do
  @moduledoc false

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec put(String.t(), String.t()) :: :ok
  def put(token, identifier) when is_binary(token) and is_binary(identifier) do
    ensure_table()
    :ets.insert(@table, {{token, identifier}, true})
    :ok
  end

  @spec delete(String.t(), String.t()) :: :ok
  def delete(token, identifier) when is_binary(token) and is_binary(identifier) do
    ensure_table()
    :ets.delete(@table, {token, identifier})
    :ok
  end

  @spec valid?(String.t(), String.t()) :: boolean()
  def valid?(token, identifier) when is_binary(token) and is_binary(identifier) do
    ensure_table()
    :ets.member(@table, {token, identifier})
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, read_concurrency: true])
      _tid -> @table
    end
  end
end

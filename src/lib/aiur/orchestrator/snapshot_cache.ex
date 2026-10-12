defmodule Aiur.Orchestrator.SnapshotCache do
  @moduledoc "Owns retained fleet snapshots independently of the projection worker."
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec get(GenServer.server()) :: map() | nil
  def get(orchestrator) do
    case :ets.lookup(__MODULE__, orchestrator) do
      [{^orchestrator, cached}] -> cached
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec put(GenServer.server(), map()) :: true
  def put(orchestrator, cached), do: :ets.insert(__MODULE__, {orchestrator, cached})

  @spec delete(GenServer.server()) :: :ok
  def delete(orchestrator) do
    :ets.delete(__MODULE__, orchestrator)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end

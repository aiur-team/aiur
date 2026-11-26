defmodule Aiur.Orchestrator.SnapshotCache do
  @moduledoc "Owns retained fleet snapshots independently of the projection worker."
  use GenServer

  alias Aiur.Project.Table

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, Aiur.Project.carry(opts), name: Aiur.Project.via(__MODULE__))
  end

  @spec get(GenServer.server()) :: map() | nil
  def get(orchestrator) do
    case :ets.lookup(Table.ref(__MODULE__), orchestrator) do
      [{^orchestrator, cached}] -> cached
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec put(GenServer.server(), map()) :: true
  def put(orchestrator, cached), do: :ets.insert(Table.ref(__MODULE__), {orchestrator, cached})

  @spec delete(GenServer.server()) :: :ok
  def delete(orchestrator) do
    :ets.delete(Table.ref(__MODULE__), orchestrator)
    :ok
  end

  @impl true
  def init(opts) do
    Aiur.Project.adopt(opts)
    Table.new(__MODULE__, [:public, :set, read_concurrency: true])
    {:ok, nil}
  end
end

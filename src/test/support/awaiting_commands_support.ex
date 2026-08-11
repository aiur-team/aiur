defmodule Aiur.TestSupport.AwaitingCommands do
  @moduledoc """
  A retained Command store double for the routes that only read canonical
  counts.

  The awaiting-Commands banner is on every route, so every route test needs a
  store that answers `:retained_counts`. This one answers exactly that, with the
  same shape the real store returns.
  """

  use GenServer

  @spec start(keyword()) :: GenServer.server()
  def start(counts) do
    name = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    {:ok, _pid} = GenServer.start_link(__MODULE__, Map.new(counts), name: name)
    name
  end

  @impl true
  def init(counts) do
    {:ok,
     Map.merge(
       %{total: 0, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0},
       counts
     )}
  end

  @doc "Moves the counts under a mounted view, the way an answered Command would."
  @spec put_counts(GenServer.server(), keyword()) :: :ok
  def put_counts(server, counts), do: GenServer.call(server, {:put_counts, Map.new(counts)})

  @impl true
  def handle_call(:health, _from, counts), do: {:reply, :writable, counts}

  def handle_call({:put_counts, next}, _from, counts), do: {:reply, :ok, Map.merge(counts, next)}

  def handle_call(:retained_counts, _from, counts) do
    {:reply, {:ok, %{counts: counts, health: :writable}}, counts}
  end
end

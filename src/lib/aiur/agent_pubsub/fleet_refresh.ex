defmodule Aiur.AgentPubSub.FleetRefresh do
  @moduledoc "Retains one current summary per consumer and coalesces mailbox invalidations."
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec register(pid()) :: :ok
  def register(pid), do: GenServer.call(__MODULE__, {:register, pid})

  @spec latest(pid()) :: [map()] | nil
  def latest(pid) do
    case :ets.lookup(__MODULE__, pid) do
      [{^pid, summaries}] -> summaries
      [] -> nil
    end
  end

  @spec dispatch([{pid(), term()}], pid() | :none, term()) :: :ok
  def dispatch(entries, from, message) do
    Enum.each(entries, fn {pid, metadata} ->
      if pid != from, do: deliver(pid, metadata, message)
    end)
  end

  defp deliver(pid, {:fleet_refresh, latch}, message) do
    if match?({:running_changed, _}, message), do: :ets.update_element(__MODULE__, pid, {2, elem(message, 1)})
    if :atomics.compare_exchange(latch, 1, 0, 1) == :ok, do: send(pid, :fleet_changed)
  rescue
    ArgumentError -> :ok
  end

  defp deliver(pid, _metadata, message), do: send(pid, message)

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, pid}, _from, monitors) do
    :ets.insert(__MODULE__, {pid, nil})
    {:reply, :ok, Map.put(monitors, Process.monitor(pid), pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, monitors) do
    :ets.delete(__MODULE__, pid)
    {:noreply, Map.delete(monitors, ref)}
  end
end

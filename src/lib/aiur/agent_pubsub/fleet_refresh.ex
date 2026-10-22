defmodule Aiur.AgentPubSub.FleetRefresh do
  @moduledoc "Retains fleet summaries, coalesces invalidations, and tracks duplicate publications."
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec register(pid()) :: :ok
  def register(pid), do: GenServer.call(__MODULE__, {:register, pid})

  @spec track_publisher(pid()) :: :ok
  def track_publisher(pid), do: GenServer.call(__MODULE__, {:track_publisher, pid})

  @spec latest(pid()) :: [map()] | nil
  def latest(pid) do
    case :ets.lookup(__MODULE__, pid) do
      [{^pid, summaries}] -> summaries
      [] -> nil
    end
  end

  @spec reset_projection_signatures(:running | :poll_state) :: :ok
  def reset_projection_signatures(key) when key in [:running, :poll_state] do
    # Make the next unchanged projection reach a newly joined subscriber.
    :ets.match_delete(__MODULE__, {{:publisher, :_, key}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec dispatch([{pid(), term()}], pid() | :none, term()) :: :ok
  def dispatch(entries, from, message) do
    Enum.each(entries, fn {pid, metadata} ->
      if pid != from, do: deliver(pid, metadata, message)
    end)
  end

  defp deliver(pid, {:fleet_refresh, latch}, message) do
    if match?({:running_changed, _}, message),
      do: :ets.update_element(__MODULE__, pid, {2, elem(message, 1)})

    if :atomics.compare_exchange(latch, 1, 0, 1) == :ok, do: send(pid, :fleet_changed)
  rescue
    ArgumentError -> :ok
  end

  defp deliver(pid, _metadata, message), do: send(pid, message)

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:register, pid}, _from, state) do
    :ets.insert(__MODULE__, {pid, nil})
    {:reply, :ok, track(state, pid)}
  end

  def handle_call({:track_publisher, pid}, _from, state), do: {:reply, :ok, track(state, pid)}

  @spec publish_if_changed(pid(), term(), term()) :: :changed | :unchanged
  def publish_if_changed(pid, key, value) when is_pid(pid) do
    # Keep this on the public ETS table: broadcast callers are already on the
    # orchestrator's hot path, so only the first publication needs a monitor
    # registration call. DOWN cleanup bounds the retained signatures.
    case :ets.insert_new(__MODULE__, {{:publisher_monitor, pid}, true}) do
      true -> track_publisher(pid)
      false -> :ok
    end

    case :ets.lookup(__MODULE__, {:publisher, pid, key}) do
      [{_, ^value}] ->
        :unchanged

      _ ->
        :ets.insert(__MODULE__, {{:publisher, pid, key}, value})
        :changed
    end
  rescue
    ArgumentError -> :changed
  catch
    :exit, _ -> :changed
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{monitors: monitors} = state) do
    :ets.delete(__MODULE__, pid)
    :ets.delete(__MODULE__, {:publisher_monitor, pid})
    :ets.match_delete(__MODULE__, {{:publisher, pid, :_}, :_})
    {:noreply, %{state | monitors: Map.delete(monitors, ref)}}
  end

  defp track(%{monitors: monitors} = state, pid) do
    if Enum.any?(monitors, fn {_ref, tracked_pid} -> tracked_pid == pid end) do
      state
    else
      %{state | monitors: Map.put(monitors, Process.monitor(pid), pid)}
    end
  end
end

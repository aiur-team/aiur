defmodule AiurWeb.FinancialDataAccess.Generation do
  @moduledoc false

  use GenServer

  @type configuration_fingerprint :: String.t()
  @type generation :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    start_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, %{fingerprint: nil, generation: nil, listeners: %{}, monitors: %{}}, start_opts)
  end

  @spec current(configuration_fingerprint(), GenServer.server()) :: {:ok, generation()} | :error
  def current(fingerprint, server \\ __MODULE__) when is_binary(fingerprint) do
    GenServer.call(server, {:synchronize, fingerprint})
  catch
    :exit, _reason -> :error
  end

  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    GenServer.call(server, :invalidate)
  catch
    :exit, _reason -> :ok
  end

  @spec subscribe(pid(), GenServer.server()) :: :ok
  def subscribe(listener \\ self(), server \\ __MODULE__) when is_pid(listener) do
    GenServer.call(server, {:subscribe, listener})
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:synchronize, fingerprint}, _from, %{fingerprint: fingerprint, generation: generation} = state)
      when is_binary(generation) do
    {:reply, {:ok, generation}, state}
  end

  def handle_call({:synchronize, fingerprint}, _from, state) do
    generation = generation()
    state = %{state | fingerprint: fingerprint, generation: generation}
    notify_listeners(state)
    {:reply, {:ok, generation}, state}
  end

  def handle_call(:invalidate, _from, %{fingerprint: nil, generation: nil} = state), do: {:reply, :ok, state}

  def handle_call(:invalidate, _from, state) do
    state = %{state | fingerprint: nil, generation: nil}
    notify_listeners(state)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, listener}, _from, state) do
    case Map.fetch(state.listeners, listener) do
      {:ok, _monitor} ->
        {:reply, :ok, state}

      :error ->
        monitor = Process.monitor(listener)

        state = %{
          state
          | listeners: Map.put(state.listeners, listener, monitor),
            monitors: Map.put(state.monitors, monitor, listener)
        }

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, listener, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {^listener, monitors} ->
        {:noreply, %{state | listeners: Map.delete(state.listeners, listener), monitors: monitors}}

      {_other, monitors} ->
        {:noreply, %{state | monitors: monitors}}
    end
  end

  defp generation do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp notify_listeners(state) do
    Enum.each(state.listeners, fn {listener, _monitor} ->
      send(listener, {AiurWeb.FinancialDataAccess, :configuration_changed, state.generation})
    end)
  end
end

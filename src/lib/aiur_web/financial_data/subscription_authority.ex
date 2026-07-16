defmodule AiurWeb.FinancialData.SubscriptionAuthority do
  @moduledoc false

  use GenServer

  alias AiurWeb.FinancialDataAccess

  @type identity :: FinancialDataAccess.identity()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    start_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, %{subscribers: %{}, monitors: %{}}, start_opts)
  end

  @spec subscribe(FinancialDataAccess.Context.t() | nil, GenServer.server()) ::
          {:ok, identity()} | {:error, :authentication_required | :unavailable}
  def subscribe(context, server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, context, self()})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec authorized_identities(GenServer.server()) :: {:ok, [identity()]} | {:error, :unavailable}
  def authorized_identities(server \\ __MODULE__) do
    GenServer.call(server, :authorized_identities)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(state) do
    :ok = FinancialDataAccess.subscribe_to_configuration_changes(self())
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, context, subscriber}, _from, state) do
    with true <- is_pid(subscriber) and Process.alive?(subscriber),
         {:ok, identity} <- FinancialDataAccess.identity(context) do
      state = remove_subscriber(state, subscriber)
      monitor = Process.monitor(subscriber)

      subscribers =
        Map.put(state.subscribers, subscriber, %{context: context, identity: identity, monitor: monitor})

      {:reply, {:ok, identity}, %{state | subscribers: subscribers, monitors: Map.put(state.monitors, monitor, subscriber)}}
    else
      false -> {:reply, {:error, :authentication_required}, state}
      {:error, :authentication_required} = error -> {:reply, error, state}
    end
  end

  def handle_call(:authorized_identities, _from, state) do
    {identities, state} =
      Enum.reduce(state.subscribers, {MapSet.new(), state}, fn {subscriber, %{context: context, identity: identity}}, {identities, state} ->
        case current_identity(subscriber, context, identity) do
          {:ok, identity} ->
            {MapSet.put(identities, identity), state}

          :remove ->
            {identities, remove_subscriber(state, subscriber)}
        end
      end)

    {:reply, {:ok, MapSet.to_list(identities)}, state}
  end

  @impl true
  def handle_info({FinancialDataAccess, :configuration_changed, _generation}, state) do
    {:noreply, clear_subscribers(state)}
  end

  def handle_info({:DOWN, monitor, :process, subscriber, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, ^subscriber} -> {:noreply, remove_subscriber(state, subscriber)}
      _other -> {:noreply, state}
    end
  end

  defp clear_subscribers(state) do
    Enum.each(state.monitors, fn {monitor, _subscriber} ->
      Process.demonitor(monitor, [:flush])
    end)

    %{state | subscribers: %{}, monitors: %{}}
  end

  defp remove_subscriber(state, subscriber) do
    case Map.pop(state.subscribers, subscriber) do
      {%{monitor: monitor}, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{state | subscribers: subscribers, monitors: Map.delete(state.monitors, monitor)}

      {nil, _subscribers} ->
        state
    end
  end

  defp current_identity(subscriber, context, identity) do
    case FinancialDataAccess.identity(context) do
      {:ok, ^identity} -> if is_pid(subscriber) and Process.alive?(subscriber), do: {:ok, identity}, else: :remove
      _stale_or_disconnected -> :remove
    end
  end
end

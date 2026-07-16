defmodule AiurWeb.FinancialData.Cache do
  @moduledoc false

  use GenServer

  alias AiurWeb.FinancialDataAccess
  alias AiurWeb.FinancialData.Cache.Pending

  @authentication_required {:error, :authentication_required}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch!(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, %{entries: %{}})
      name -> GenServer.start_link(__MODULE__, %{entries: %{}}, name: name)
    end
  end

  @spec fetch(
          GenServer.server(),
          FinancialDataAccess.Context.t(),
          {String.t(), String.t()},
          atom(),
          term(),
          non_neg_integer(),
          (-> term())
        ) :: {:ok, term()} | {:error, :authentication_required | :provider_unavailable}
  def fetch(server, context, identity, source, key, max_age_ms, loader) do
    GenServer.call(server, {:fetch, context, identity, source, key, max_age_ms, loader}, :infinity)
  end

  @spec evict_stale_configuration(GenServer.server()) :: :ok
  def evict_stale_configuration(server) do
    GenServer.call(server, :evict_stale_configuration)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(state) do
    {:ok, worker_supervisor} = Task.Supervisor.start_link()
    :ok = FinancialDataAccess.subscribe_to_configuration_changes(self())
    {:ok, state |> Map.put(:worker_supervisor, worker_supervisor) |> Pending.initialize()}
  end

  @impl true
  def terminate(_reason, state) do
    _ = Pending.clear(state)

    if Process.alive?(state.worker_supervisor) do
      Process.unlink(state.worker_supervisor)
      Supervisor.stop(state.worker_supervisor, :shutdown)
    end

    :ok
  end

  @impl true
  def handle_call(
        {:fetch, context, identity, source, key, max_age_ms, loader},
        from,
        state
      ) do
    case FinancialDataAccess.identity(context) do
      {:ok, ^identity} ->
        state = prune_stale_configuration(state)
        fetch_authorized(state, context, identity, source, key, max_age_ms, from, loader)

      _denied ->
        {:reply, @authentication_required, state}
    end
  end

  def handle_call(:evict_stale_configuration, _from, state) do
    {:reply, :ok, prune_stale_configuration(state)}
  end

  @impl true
  def handle_info({FinancialDataAccess, :configuration_changed, _generation}, state) do
    {:noreply, state |> Map.put(:entries, %{}) |> Pending.clear()}
  end

  def handle_info({:financial_data_loaded, load_ref, result}, state) do
    {:noreply, Pending.resolve_loaded(state, load_ref, result)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, Pending.resolve_down(state, monitor)}
  end

  defp deliver_cached(state, context, identity, payload) do
    case FinancialDataAccess.identity(context) do
      {:ok, ^identity} -> {:reply, {:ok, payload}, state}
      _stale_or_denied -> {:reply, @authentication_required, prune_stale_configuration(state)}
    end
  end

  defp fetch_authorized(state, context, identity, source, key, max_age_ms, from, loader) do
    cache_key = cache_key(identity, source, key)
    now_ms = System.monotonic_time(:millisecond)

    case get_in(state, [:entries, cache_key]) do
      %{loaded_at_ms: loaded_at_ms, payload: payload} when now_ms - loaded_at_ms < max_age_ms ->
        deliver_cached(state, context, identity, payload)

      _missing_or_expired ->
        Pending.enqueue(state, cache_key, context, identity, from, loader)
    end
  end

  defp prune_stale_configuration(state) do
    current_generation =
      case FinancialDataAccess.current_configuration_generation() do
        {:ok, generation} -> generation
        _denied -> nil
      end

    entries =
      Map.reject(state.entries, fn
        {{configuration_generation, _connection_generation, _source, _key}, _entry} ->
          configuration_generation != current_generation

        {_unexpected_key, _entry} ->
          true
      end)

    state
    |> Map.put(:entries, entries)
    |> Pending.drop_stale(current_generation)
  end

  defp cache_key({configuration_generation, connection_generation}, source, key),
    do: {configuration_generation, connection_generation, source, key}
end

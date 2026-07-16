defmodule AiurWeb.FinancialData.Cache.Pending do
  @moduledoc false

  alias AiurWeb.FinancialDataAccess

  @authentication_required {:error, :authentication_required}
  @max_entries 8
  @max_pending @max_entries
  @max_waiters_per_load @max_entries

  @type state :: map()
  @type identity :: FinancialDataAccess.identity()
  @type loader :: (-> term())

  @spec initialize(state()) :: state()
  def initialize(state), do: Map.merge(%{pending: %{}, pending_loads: %{}, pending_monitors: %{}}, state)

  @spec enqueue(state(), term(), FinancialDataAccess.Context.t(), identity(), GenServer.from(), loader()) ::
          {:noreply, state()} | {:reply, {:error, :provider_unavailable}, state()}
  def enqueue(state, cache_key, context, identity, from, loader) do
    waiter = %{context: context, from: from, identity: identity, pid: caller_pid(from)}

    case Map.fetch(state.pending, cache_key) do
      {:ok, pending} ->
        if length(pending.waiters) >= @max_waiters_per_load do
          {:reply, {:error, :provider_unavailable}, state}
        else
          pending = %{pending | waiters: [waiter | pending.waiters]}
          {:noreply, put_in(state, [:pending, cache_key], pending)}
        end

      :error when map_size(state.pending) >= @max_pending ->
        {:reply, {:error, :provider_unavailable}, state}

      :error ->
        load_ref = make_ref()
        cache = self()

        {:ok, pid} =
          Task.Supervisor.start_child(state.worker_supervisor, fn ->
            result =
              case FinancialDataAccess.identity(context) do
                {:ok, ^identity} -> safe_load(loader)
                _stale_or_denied -> :denied
              end

            send(cache, {:financial_data_loaded, load_ref, result})
          end)

        monitor = Process.monitor(pid)

        pending = %{
          cache_key: cache_key,
          identity: identity,
          load_ref: load_ref,
          monitor: monitor,
          pid: pid,
          waiters: [waiter]
        }

        state = %{
          state
          | pending: Map.put(state.pending, cache_key, pending),
            pending_loads: Map.put(state.pending_loads, load_ref, cache_key),
            pending_monitors: Map.put(state.pending_monitors, monitor, cache_key)
        }

        {:noreply, state}
    end
  end

  @spec resolve_loaded(state(), reference(), {:ok, term()} | :denied | :error) :: state()
  def resolve_loaded(state, load_ref, result) do
    with {:ok, cache_key} <- Map.fetch(state.pending_loads, load_ref),
         {pending, state} <- pop(state, cache_key) do
      resolve_result(state, pending, result)
    else
      :error -> state
    end
  end

  @spec resolve_down(state(), reference()) :: state()
  def resolve_down(state, monitor) do
    with {:ok, cache_key} <- Map.fetch(state.pending_monitors, monitor),
         {pending, state} <- pop(state, cache_key) do
      resolve_result(state, pending, :error)
    else
      :error -> state
    end
  end

  @spec clear(state()) :: state()
  def clear(state) do
    Enum.reduce(Map.keys(state.pending), state, fn cache_key, state ->
      {pending, state} = pop(state, cache_key)
      stop_worker(pending)
      reply_waiters(pending.waiters, @authentication_required)
      state
    end)
  end

  @spec drop_stale(state(), String.t() | nil) :: state()
  def drop_stale(state, current_generation) do
    Enum.reduce(Map.keys(state.pending), state, fn cache_key, state ->
      %{identity: {configuration_generation, _connection_generation}} = pending = state.pending[cache_key]

      if configuration_generation == current_generation do
        state
      else
        {^pending, state} = pop(state, cache_key)
        stop_worker(pending)
        reply_waiters(pending.waiters, @authentication_required)
        state
      end
    end)
  end

  defp resolve_result(state, pending, {:ok, payload}) do
    {authorized, denied} = Enum.split_with(pending.waiters, &authorized_waiter?/1)
    reply_waiters(authorized, {:ok, payload})
    reply_waiters(denied, @authentication_required)

    if authorized == [] do
      state
    else
      entry = %{
        loaded_at_ms: System.monotonic_time(:millisecond),
        load_order: System.unique_integer([:monotonic, :positive]),
        payload: payload
      }

      entries = state.entries |> Map.put(pending.cache_key, entry) |> bound_entries()
      %{state | entries: entries}
    end
  end

  defp resolve_result(state, pending, :error) do
    {authorized, denied} = Enum.split_with(pending.waiters, &authorized_waiter?/1)
    reply_waiters(authorized, {:error, :provider_unavailable})
    reply_waiters(denied, @authentication_required)
    state
  end

  defp resolve_result(state, pending, :denied) do
    reply_waiters(pending.waiters, @authentication_required)
    state
  end

  defp authorized_waiter?(%{context: context, identity: identity, pid: pid}) do
    is_pid(pid) and Process.alive?(pid) and FinancialDataAccess.identity(context) == {:ok, identity}
  end

  defp reply_waiters(waiters, reply) do
    Enum.each(waiters, fn %{from: from, pid: pid} ->
      if is_pid(pid) and Process.alive?(pid), do: GenServer.reply(from, reply)
    end)
  end

  defp pop(state, cache_key) do
    case Map.pop(state.pending, cache_key) do
      {nil, _pending} ->
        {nil, state}

      {pending, pending_entries} ->
        Process.demonitor(pending.monitor, [:flush])

        state = %{
          state
          | pending: pending_entries,
            pending_loads: Map.delete(state.pending_loads, pending.load_ref),
            pending_monitors: Map.delete(state.pending_monitors, pending.monitor)
        }

        {pending, state}
    end
  end

  defp stop_worker(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end

  defp caller_pid({pid, _tag}) when is_pid(pid), do: pid

  defp safe_load(loader) do
    {:ok, loader.()}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp bound_entries(entries) when map_size(entries) <= @max_entries, do: entries

  defp bound_entries(entries) do
    entries
    |> Enum.sort_by(fn {_key, entry} -> entry.load_order end, :desc)
    |> Enum.take(@max_entries)
    |> Map.new()
  end
end

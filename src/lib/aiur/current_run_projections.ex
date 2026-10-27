defmodule Aiur.CurrentRunProjections do
  @moduledoc """
  Owns the two current-run read models behind one supervised runtime child.

  Source reads run concurrently outside the owner. While a bounded refresh is
  in flight, read APIs keep serving the prior snapshot with explicit stale and
  refreshing provenance. Run-fenced projection checkpoints preserve public
  generations and terminal complexity facts across same-run owner restarts.
  """

  use GenServer

  alias Aiur.CurrentRunProjections.{CheckpointPersistence, Refresh, SourceCollector, State}

  @type projection :: :summary | :outcomes
  @refresh_timeout 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec snapshot(projection(), keyword()) :: map()
  def snapshot(projection, opts \\ []) when projection in [:summary, :outcomes] do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:snapshot, projection})
  end

  @spec health(projection(), keyword()) :: map()
  def health(projection, opts \\ []), do: snapshot(projection, opts).health

  @spec freshness(projection(), keyword()) :: map()
  def freshness(projection, opts \\ []), do: snapshot(projection, opts).freshness

  @spec generation(projection(), keyword()) :: non_neg_integer()
  def generation(projection, opts \\ []), do: snapshot(projection, opts).generation

  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, @refresh_timeout)

  @doc false
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @impl true
  def init(opts) do
    state = State.new(opts)
    safe_subscribe(state.membership_subscribe_fun)
    state = if state.active?, do: activate(state), else: activate_idle(state)

    state =
      if state.active? and Keyword.get(opts, :refresh_on_init?, true) do
        request_initial_refresh(state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:snapshot, :summary}, _from, state),
    do: {:reply, state.summary_snapshot, state}

  def handle_call({:snapshot, :outcomes}, _from, state),
    do: {:reply, state.outcome_snapshot, state}

  def handle_call({:subscribe, pid}, _from, state) do
    state = add_subscriber(state, pid)
    was_active? = state.active?
    state = if was_active?, do: state, else: activate(state)
    state = if was_active?, do: state, else: request_initial_refresh(state)
    {:reply, :ok, state}
  end

  def handle_call(:refresh, from, %{checkpoint_write: write} = state) when is_map(write) do
    {:noreply, queue_waiter(state, from)}
  end

  def handle_call(:refresh, from, %{refresh: nil} = state) do
    {:noreply, Refresh.start(%{state | refresh_pending?: false}, :full, [from])}
  end

  def handle_call(:refresh, from, %{refresh: refresh} = state) when is_map(refresh) do
    {:noreply, queue_waiter(state, from)}
  end

  @impl true
  def handle_info(
        :refresh_sources,
        %{refresh_pending?: true, refresh: nil, checkpoint_write: nil} = state
      ) do
    {:noreply, Refresh.start(%{state | refresh_pending?: false}, :full)}
  end

  def handle_info(:refresh_sources, state), do: {:noreply, state}

  def handle_info(:clock_tick, %{active?: true} = state) do
    state = %{state | clock_timer_ref: schedule(:clock_tick, state.clock_interval_ms)}

    state =
      if is_nil(state.refresh) and is_nil(state.checkpoint_write) and not state.refresh_pending? do
        Refresh.start(state, :clock)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:clock_tick, state), do: {:noreply, state}

  def handle_info(:reconcile_tick, state) do
    state = %{state | reconcile_timer_ref: schedule(:reconcile_tick, state.reconcile_interval_ms)}
    {:noreply, Refresh.request_full(state)}
  end

  def handle_info({:current_run_source_result, ref, key, result}, %{refresh: %{ref: ref} = refresh} = state) do
    refresh = SourceCollector.put_result(refresh, key, result)

    if SourceCollector.complete?(refresh) do
      {:noreply, Refresh.finish(%{state | refresh: refresh})}
    else
      {:noreply, %{state | refresh: refresh}}
    end
  end

  def handle_info({:current_run_source_deadline, ref}, %{refresh: %{ref: ref} = refresh} = state) do
    {:noreply, Refresh.finish(%{state | refresh: SourceCollector.expire(refresh)})}
  end

  def handle_info({:current_run_checkpoint_result, ref, generation, result}, state) do
    {:noreply, Refresh.finish_checkpoint(state, ref, generation, result)}
  end

  def handle_info({:current_run_checkpoint_deadline, ref, generation}, state) do
    {:noreply, Refresh.expire_checkpoint(state, ref, generation)}
  end

  def handle_info({:current_run_membership_changed, _payload}, state),
    do: {:noreply, membership_refresh(state)}

  def handle_info({:current_run_membership_health_changed, _payload}, state),
    do: {:noreply, membership_refresh(state)}

  def handle_info({:ticket_activity_changed, _payload}, state),
    do: {:noreply, schedule_refresh(state)}

  def handle_info({:running_changed, _payload}, state),
    do: {:noreply, schedule_refresh(state)}

  def handle_info({:status_changed, _payload}, state),
    do: {:noreply, schedule_refresh(state)}

  def handle_info(:observability_updated, state), do: {:noreply, schedule_refresh(state)}
  def handle_info({:observability_updated, _event_id}, state), do: {:noreply, schedule_refresh(state)}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.subscribers, pid) do
      {^ref, subscribers} ->
        state = %{state | subscribers: subscribers}
        {:noreply, if(map_size(subscribers) == 0, do: deactivate_if_idle(state), else: state)}

      {_other, _subscribers} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_map(state.refresh), do: SourceCollector.finish(state.refresh)
    CheckpointPersistence.stop(state.checkpoint_write)
  end

  defp queue_waiter(state, from), do: %{state | queued_waiters: [from | state.queued_waiters]}

  defp activate(state) do
    Enum.each(state.subscribe_funs, &safe_subscribe/1)

    %{
      state
      | active?: true,
        clock_timer_ref: schedule(:clock_tick, state.clock_interval_ms),
        reconcile_timer_ref: state.reconcile_timer_ref || schedule(:reconcile_tick, state.reconcile_interval_ms)
    }
  end

  defp activate_idle(state) do
    %{state | reconcile_timer_ref: schedule(:reconcile_tick, state.reconcile_interval_ms)}
  end

  defp deactivate_if_idle(%{idle_without_subscribers?: true} = state) do
    cancel_timer(state.clock_timer_ref)

    %{state | active?: false, clock_timer_ref: nil, refresh_pending?: false}
  end

  defp deactivate_if_idle(state), do: state

  defp add_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid) do
      state
    else
      %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
    end
  end

  defp request_initial_refresh(state) do
    if state.active? and is_nil(state.refresh) and not state.refresh_pending? do
      send(self(), :refresh_sources)
      %{state | refresh_pending?: true}
    else
      state
    end
  end

  defp schedule_refresh(%{active?: true} = state), do: Refresh.schedule(state)
  defp schedule_refresh(state), do: state

  defp membership_refresh(%{active?: true} = state), do: Refresh.schedule(state)

  defp membership_refresh(%{idle_without_subscribers?: true} = state),
    do: Refresh.schedule(state)

  defp membership_refresh(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp safe_subscribe(fun) do
    fun.()
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp schedule(_message, :infinity), do: nil
  defp schedule(message, interval), do: Process.send_after(self(), message, interval)
end

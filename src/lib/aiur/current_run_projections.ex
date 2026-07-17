defmodule Aiur.CurrentRunProjections do
  @moduledoc """
  Owns the two current-run read models behind one supervised runtime child.

  Source reads run concurrently outside the owner. While a bounded refresh is
  in flight, read APIs keep serving the prior snapshot with explicit stale and
  refreshing provenance. Run-fenced projection checkpoints preserve public
  generations and terminal complexity facts across same-run owner restarts.
  """

  use GenServer

  alias Aiur.CurrentRunProjections.{Refresh, SourceCollector, State}

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

  @impl true
  def init(opts) do
    state = State.new(opts)
    subscribe(opts)
    schedule(:clock_tick, state.clock_interval_ms)
    schedule(:reconcile_tick, state.reconcile_interval_ms)

    state =
      if Keyword.get(opts, :refresh_on_init?, true) do
        send(self(), :refresh_sources)
        %{state | refresh_pending?: true}
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

  def handle_call(:refresh, from, %{refresh: nil} = state) do
    {:noreply, Refresh.start(%{state | refresh_pending?: false}, :full, [from])}
  end

  def handle_call(:refresh, from, %{refresh: %{mode: :full} = refresh} = state) do
    {:noreply, %{state | refresh: SourceCollector.add_waiter(refresh, from)}}
  end

  def handle_call(:refresh, from, %{refresh: %{mode: :clock}} = state) do
    {:noreply, %{state | refresh_again?: true, queued_waiters: [from | state.queued_waiters]}}
  end

  @impl true
  def handle_info(:refresh_sources, %{refresh_pending?: true, refresh: nil} = state) do
    {:noreply, Refresh.start(%{state | refresh_pending?: false}, :full)}
  end

  def handle_info(:refresh_sources, state), do: {:noreply, state}

  def handle_info(:clock_tick, state) do
    schedule(:clock_tick, state.clock_interval_ms)

    state =
      if is_nil(state.refresh) and not state.refresh_pending? do
        Refresh.start(state, :clock)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:reconcile_tick, state) do
    schedule(:reconcile_tick, state.reconcile_interval_ms)
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

  def handle_info({:current_run_membership_changed, _payload}, state),
    do: {:noreply, Refresh.schedule(state)}

  def handle_info({:current_run_membership_health_changed, _payload}, state),
    do: {:noreply, Refresh.schedule(state)}

  def handle_info({:ticket_activity_changed, _payload}, state),
    do: {:noreply, Refresh.schedule(state)}

  def handle_info({:running_changed, _payload}, state),
    do: {:noreply, Refresh.schedule(state)}

  def handle_info({:status_changed, _payload}, state),
    do: {:noreply, Refresh.schedule(state)}

  def handle_info(:observability_updated, state), do: {:noreply, Refresh.schedule(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{refresh: refresh}) when is_map(refresh), do: SourceCollector.finish(refresh)
  def terminate(_reason, _state), do: :ok

  defp subscribe(opts) do
    opts
    |> Keyword.get(:subscribe_funs, [
      &Aiur.CurrentRunMembership.subscribe/0,
      &Aiur.TicketActivity.subscribe/0,
      &Aiur.AgentPubSub.subscribe_running/0,
      &Aiur.AgentPubSub.subscribe_status/0,
      &AiurWeb.ObservabilityPubSub.subscribe/0
    ])
    |> Enum.each(&safe_subscribe/1)
  end

  defp safe_subscribe(fun) do
    fun.()
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp schedule(_message, :infinity), do: :ok
  defp schedule(message, interval), do: Process.send_after(self(), message, interval)
end

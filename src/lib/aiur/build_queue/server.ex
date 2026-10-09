defmodule Aiur.BuildQueue.Server do
  @moduledoc "Owns dispatch hints and coalesces tracker signals into queue plans and executes paced label writes."
  use GenServer
  require Logger

  alias Aiur.BuildQueue.{Bookkeeping, ClaimProbe, Hints, Reconcile, Recovery, Settings, Store, Writer}
  alias Aiur.Events.Exchange

  @patterns ["ticket.*.pr.merged", "ticket.*.issue.label.added.agent.*", "ticket.*.agent.attention.#", "ticket.*.dependency.merged_blocker_reconciled"]
  @debounce_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok, settings} = Keyword.get_lazy(opts, :settings, &Aiur.Config.settings/0)

    state = %{
      settings: settings,
      writer: Writer.new(),
      write_results: [],
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      tracker: Keyword.get(opts, :tracker, Aiur.Tracker),
      store: Keyword.get(opts, :store, Store),
      claim_probe: Keyword.get(opts, :claim_probe, ClaimProbe),
      clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
      schedule: Keyword.get(opts, :schedule, &Process.send_after/3),
      exchange: Keyword.get(opts, :exchange, Exchange),
      exchange_pid: nil,
      pending: nil,
      status: :disabled,
      phase: :awaiting_first_observation,
      freshness: :unknown,
      document: nil,
      projections: [],
      actions: [],
      holds: MapSet.new(),
      closure_cache: %{},
      intent_reconciles: %{},
      reconciles: 0
    }

    {:ok, initialize(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:show, _from, state), do: {:reply, {:ok, Map.take(state, [:status, :phase, :freshness, :projections, :actions, :reconciles])}, state}

  def handle_call({:write, action, id}, _from, %{status: status} = state) when action in [:mark, :unmark] and status == :running and state.phase == :ready do
    state = write(state, [{action, id}], Reconcile.observations(state))
    {:reply, state.write_results |> List.last() |> elem(2), state}
  end

  def handle_call({:write, _, _}, _from, %{phase: :awaiting_first_observation, status: :running} = state), do: {:reply, {:error, :awaiting_first_observation}, state}

  def handle_call(:recover, _from, %{status: status} = state) when status in [:disabled, :unsupported_tracker], do: {:reply, {:error, status}, state}

  def handle_call(:recover, _from, state) do
    case Recovery.rebuild(state) do
      {:ok, document} ->
        if state.status == :store_unavailable do
          Phoenix.PubSub.subscribe(Aiur.PubSub, "tracker:open_issues")
          schedule_tick(state)
        end

        state = %{state | document: document, status: :running, phase: :ready, freshness: :fresh, writer: Writer.new(), holds: MapSet.new()}
        {projections, _, _, _} = Reconcile.plan(state)
        Reconcile.write_hints(projections, state.holds, document)
        {:reply, :ok, state |> subscribe() |> request()}

      {:error, reason} = error when reason in [:store_present, :observation_unavailable] ->
        {:reply, error, state}

      {:error, _reason} = error ->
        {:reply, error, %{state | status: :store_unavailable}}
    end
  end

  def handle_call({:write, _, _}, _from, state), do: {:reply, {:error, state.status}, state}
  def handle_call(:reconcile_now, _from, state), do: {:reply, :ok, request(state)}

  def handle_call({:release, target}, _from, %{status: status} = state) when status in [:running, :writes_paused] do
    observations = Reconcile.observations(state)

    with {:ok, document} <- Bookkeeping.release(state.document, target, observations, state.clock.(), "#{state.settings.tracker.github.label_prefix}:todo"),
         :ok <- state.store.save(document) do
      released = for item <- state.document.items, item.issue_id == target or item.queue_id == target, do: item.issue_id
      {:reply, :ok, request(%{state | document: document, holds: MapSet.difference(state.holds, MapSet.new(released))})}
    else
      {:error, reason} when reason in [:not_found, :observation_unavailable] -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | status: :store_unavailable}}
    end
  end

  def handle_call({:release, _target}, _from, state), do: {:reply, {:error, state.status}, state}

  @impl true
  def handle_info({:open_issues_recorded, _}, state), do: {:noreply, request(state)}
  def handle_info({:event, _}, state), do: {:noreply, request(state)}

  def handle_info(:tick, %{status: status} = state) when status in [:running, :writes_paused] do
    schedule_tick(state)
    {:noreply, state |> subscribe() |> request()}
  end

  def handle_info({:reconcile, token}, %{pending: token, status: status} = state) when status in [:running, :writes_paused] do
    {:noreply, reconcile(%{state | pending: nil})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{exchange_pid: pid} = state), do: {:noreply, %{state | exchange_pid: nil}}
  def handle_info(_message, state), do: {:noreply, state}

  defp initialize(%{settings: %{build_queue: %{enabled: false}}} = state), do: state

  defp initialize(state) do
    if state.tracker.open_issue_labels(1) == {:error, :unsupported} do
      %{state | status: :unsupported_tracker}
    else
      :ets.new(Hints.table_name(), [:named_table, :set, :protected, read_concurrency: true])
      recover(state)
    end
  end

  defp recover(state) do
    # Safe ETF decoding needs the producer atoms present before store recovery.
    Enum.each([Aiur.BuildQueue.Planner, Aiur.BuildQueue.PlannerPolicy, Aiur.BuildQueue.Readiness, Aiur.BuildQueue.Attention, Recovery], &Code.ensure_loaded!/1)

    case state.store.load() do
      {:ok, document} ->
        Phoenix.PubSub.subscribe(Aiur.PubSub, "tracker:open_issues")
        state = %{state | status: :running, document: document}
        schedule_tick(state)
        state |> subscribe() |> request()

      {:error, reason} ->
        Logger.error("Build queue store unavailable: #{inspect(reason)}")
        %{state | status: :store_unavailable}
    end
  end

  defp schedule_tick(state), do: state.schedule.(self(), :tick, state.settings.build_queue.reconcile_interval_seconds * 1000)

  defp request(%{status: status, pending: nil} = state) when status in [:running, :writes_paused] do
    token = make_ref()
    state.schedule.(self(), {:reconcile, token}, @debounce_ms)
    %{state | pending: token}
  end

  defp request(state), do: state

  defp reconcile(state) do
    {freshness, observations} = Reconcile.snapshot(state)
    state = Recovery.resolve(%{state | freshness: freshness}, observations)
    plan(state, observations)
  end

  defp plan(state, observations) do
    {projections, actions, observations, cache} = Reconcile.plan(state, observations)
    state = %{state | closure_cache: cache}
    state = if state.phase == :ready and state.status != :store_unavailable, do: write(state, actions, observations), else: %{state | actions: actions}

    holds =
      Enum.reduce(actions, state.holds, fn
        {:begin_withdraw, id}, holds -> MapSet.put(holds, id)
        {:hold_release, id}, holds -> MapSet.delete(holds, id)
        _, holds -> holds
      end)

    retained = for p <- projections, p.state not in [:removed, :completed, :cancelled], do: p.issue_id
    holds = MapSet.intersection(holds, MapSet.new(retained))
    Reconcile.write_hints(projections, holds, state.document)
    Phoenix.PubSub.broadcast(Aiur.PubSub, "build_queue:changed", {:build_queue_changed, state.status})
    state = %{state | projections: projections, actions: state.actions, holds: holds, reconciles: state.reconciles + 1}
    if Enum.any?(actions, &match?({:dequeue, _}, &1)), do: request(state), else: state
  end

  defp write(state, actions, observations) do
    prefix = state.settings.tracker.github.label_prefix

    context =
      Map.merge(state, %{
        observations: observations,
        marker: "#{prefix}:queued",
        todo: "#{prefix}:todo",
        max_writes: state.settings.build_queue.max_writes_per_minute,
        observation_max_age_ms: Settings.observation_max_age_ms(state.settings)
      })

    result = Writer.run(context, actions, state.writer)
    status = if result.status == :paced, do: :running, else: result.status
    ages = Map.new(result.document.intents, &{&1.id, Map.get(state.intent_reconciles, &1.id, state.reconciles)})
    %{state | document: result.document, writer: result.writer, write_results: result.write_results, status: status, actions: actions ++ result.write_attentions, intent_reconciles: ages}
  end

  defp subscribe(%{exchange_pid: pid} = state) when is_pid(pid), do: state

  defp subscribe(state) do
    case GenServer.whereis(state.exchange) do
      nil -> state
      pid -> bind(state, pid)
    end
  end

  defp bind(state, pid) do
    Enum.each(@patterns, &Exchange.subscribe(&1, state.exchange))
    Process.monitor(pid)
    %{state | exchange_pid: pid}
  catch
    :exit, reason ->
      Logger.warning("Build queue Exchange subscription unavailable: #{inspect(reason)}")
      state
  end
end

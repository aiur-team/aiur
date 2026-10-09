defmodule Aiur.BuildQueue.Server do
  @moduledoc "Owns dispatch hints and coalesces tracker signals into queue plans and executes paced label writes."
  use GenServer
  require Logger

  alias Aiur.BuildQueue.{
    AttentionActions,
    AttentionHealth,
    Bookkeeping,
    BuildOrderCommands,
    ClaimProbe,
    Events,
    Hints,
    ListCommands,
    Progress,
    ReadModel,
    Reconcile,
    Recovery,
    Settings,
    Store,
    Withdrawal,
    Writer
  }

  alias Aiur.BuildQueue.Sources.BuildOrder, as: BuildOrderSource
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
      observations: %{},
      observed_at_ms: nil,
      actions: [],
      holds: MapSet.new(),
      build_order_projection: Keyword.get(opts, :build_order_projection, BuildOrderSource.projection()),
      sources: %{},
      source_verdicts: %{},
      source_refreshes: %{},
      published_pr_versions: %{},
      merged_at_ms: %{},
      hold_ages: %{},
      closure_cache: %{},
      intent_reconciles: %{},
      inputs_unknown_since_ms: nil,
      store_attention?: false,
      planned_edges: [],
      reconciles: 0
    }

    {:ok, state |> initialize() |> AttentionHealth.store()}
  end

  @impl true
  def handle_call(:read_model, _from, state), do: {:reply, ReadModel.build(state), state}
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:show, _from, state) do
    model = Map.take(state, [:status, :phase, :freshness, :projections, :actions, :reconciles, :sources])
    model = Map.put(model, :build_queue, %{build_order_source: BuildOrderSource.available?(state.build_order_projection)})
    {:reply, {:ok, model}, state}
  end

  def handle_call({:write, action, id}, _from, %{status: status} = state) when action in [:mark, :unmark] and status == :running and state.phase == :ready do
    state = write(state, [{action, id}], Reconcile.observations(state))
    {:reply, state.write_results |> List.last() |> elem(2), state}
  end

  def handle_call({:write, _, _}, _from, %{phase: :awaiting_first_observation, status: :running} = state), do: {:reply, {:error, :awaiting_first_observation}, state}

  def handle_call(:recover, _from, %{status: status} = state) when status in [:disabled, :unsupported_tracker], do: {:reply, {:error, status}, state}

  def handle_call(:recover, from, %{status: :store_unavailable} = state) do
    case state.store.load() do
      {:ok, document} ->
        Phoenix.PubSub.subscribe(Aiur.PubSub, "tracker:open_issues")
        schedule_tick(state)
        state = %{state | document: document, status: :running, phase: :awaiting_first_observation, pending: nil, writer: Writer.new()}
        {:reply, :ok, state |> AttentionHealth.store() |> subscribe() |> request()}

      {:error, _} ->
        rebuild(from, state)
    end
  end

  def handle_call(:recover, from, state), do: rebuild(from, state)

  def handle_call({:write, _, _}, _from, state), do: {:reply, {:error, state.status}, state}

  def handle_call({:mutate, _}, _from, %{phase: :awaiting_first_observation, status: :running} = state), do: {:reply, {:error, :awaiting_first_observation}, state}

  def handle_call({:mutate, {verb, root} = command}, _from, %{status: :running} = state) when verb in [:adopt, :unadopt] do
    case BuildOrderCommands.prepare(state, command) do
      {:ok, document, actions, observations, updates} ->
        {reply, state} = commit_mutation(state, document, actions, observations)
        if state.status != :store_unavailable and verb == :unadopt, do: BuildOrderCommands.release(root, state)
        state = if state.status != :store_unavailable, do: Map.merge(state, Map.delete(updates, :refusals)), else: state
        state = if verb == :adopt, do: BuildOrderCommands.refresh_unavailable(state), else: state
        reply = if reply == :ok, do: {:ok, updates.refusals}, else: reply
        {:reply, reply, request(state)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:mutate, command}, _from, %{status: :running} = state) do
    case ListCommands.prepare(state, command) do
      {:ok, document, actions, observations} ->
        {reply, state} = commit_mutation(state, document, actions, observations)
        {:reply, reply, request(state)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:mutate, _}, _from, state), do: {:reply, {:error, state.status}, state}
  def handle_call(:reconcile_now, _from, state), do: {:reply, :ok, request(state)}

  def handle_call({:release, target}, _from, %{status: status} = state) when status in [:running, :writes_paused] do
    observations = Reconcile.observations(state)

    with {:ok, document} <- Bookkeeping.release(state.document, target, observations, state.clock.(), "#{state.settings.tracker.github.label_prefix}:todo"),
         :ok <- state.store.save(document) do
      Events.saved(state.document, document)
      released = for item <- state.document.items, item.issue_id == target or item.queue_id == target, do: item.issue_id
      {:reply, :ok, request(%{state | document: document, holds: MapSet.difference(state.holds, MapSet.new(released))})}
    else
      {:error, reason} when reason in [:not_found, :observation_unavailable] -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, AttentionHealth.store(%{state | status: :store_unavailable})}
    end
  end

  def handle_call({:release, _target}, _from, state), do: {:reply, {:error, state.status}, state}

  @impl true
  def handle_info({:open_issues_recorded, _}, state), do: {:noreply, state |> BuildOrderCommands.hint() |> request()}
  def handle_info({:graph_projection_reset, _}, state), do: {:noreply, request(state)}

  def handle_info({:event, %{topic: "ticket." <> topic}}, state) do
    state =
      case String.split(topic, ".") do
        [id, "pr", "merged"] -> %{state | merged_at_ms: Map.put_new(state.merged_at_ms, id, state.clock.())}
        _ -> state
      end

    {:noreply, state |> BuildOrderCommands.hint() |> request()}
  end

  def handle_info({:event, _}, state), do: {:noreply, state |> BuildOrderCommands.hint() |> request()}

  def handle_info({kind, snapshot}, state) when kind in [:graph_projection_generation, :graph_projection_health] do
    root = BuildOrderCommands.generation_root(snapshot)
    if state.document && Enum.any?(state.document.queues, &(&1.kind == :build_order and &1.root == root)), do: {:noreply, request(state)}, else: {:noreply, state}
  end

  def handle_info(:tick, %{status: status} = state) when status in [:running, :writes_paused] do
    schedule_tick(state)
    {:noreply, state |> subscribe() |> request()}
  end

  def handle_info({:reconcile, token}, %{pending: token, status: status} = state) when status in [:running, :writes_paused] do
    {:noreply, reconcile(%{state | pending: nil})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{exchange_pid: pid} = state), do: {:noreply, %{state | exchange_pid: nil}}
  def handle_info(_message, state), do: {:noreply, state}

  defp rebuild(_from, state) do
    case Recovery.rebuild(state) do
      {:ok, document} ->
        if state.status == :store_unavailable do
          Phoenix.PubSub.subscribe(Aiur.PubSub, "tracker:open_issues")
          schedule_tick(state)
        end

        state = %{state | document: document, status: :running, phase: :ready, freshness: :fresh, writer: Writer.new(), holds: MapSet.new()}
        {projections, _, _, _, _, published, _edges} = Reconcile.plan(state)
        state = %{state | published_pr_versions: published}
        Reconcile.write_hints(projections, state.holds, document)
        {:reply, :ok, state |> AttentionHealth.store() |> subscribe() |> request()}

      {:error, reason} = error when reason in [:store_present, :observation_unavailable] ->
        {:reply, error, state}

      {:error, _reason} = error ->
        {:reply, error, AttentionHealth.store(%{state | status: :store_unavailable})}
    end
  end

  defp commit_mutation(state, document, actions, observations) do
    case state.store.save(document) do
      :ok ->
        Events.saved(state.document, document, :operator)
        state = write(%{state | document: document}, actions, observations)

        failures =
          state.write_results
          |> Enum.reverse()
          |> Enum.uniq_by(&{elem(&1, 0), elem(&1, 1)})
          |> Enum.reject(&(elem(&1, 2) == :ok))
          |> Enum.reverse()

        reply = if failures == [], do: :ok, else: {:error, {:marker_write_failed, failures}}
        {reply, state}

      {:error, _} ->
        {{:error, :store_unavailable}, AttentionHealth.store(%{state | status: :store_unavailable})}
    end
  end

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
        AttentionHealth.store(%{state | status: :store_unavailable})
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
    {freshness, observations, observed_at_ms} = Reconcile.observed_snapshot(state)
    state = Recovery.resolve(%{state | freshness: freshness, observed_at_ms: observed_at_ms}, observations)
    state = state |> sync_sources(observations) |> replay_list_markers(observations)
    plan(state, Reconcile.observations(state))
  end

  defp sync_sources(%{phase: :ready, status: status} = state, observations) when status in [:running, :writes_paused] do
    {document, actions, sources, verdicts} = BuildOrderCommands.sync(state)
    state = %{state | sources: sources, source_verdicts: verdicts} |> BuildOrderCommands.refresh_unavailable()

    if document == state.document do
      state
    else
      document = ListCommands.record(state, document, actions, observations)
      {_reply, state} = commit_mutation(state, document, actions, observations)
      state
    end
  end

  defp sync_sources(state, _observations), do: state

  # Marker requests survive pacing and restarts; replay them only once recovery has resolved the store.
  defp replay_list_markers(%{phase: :ready, status: status} = state, observations) when status in [:running, :writes_paused] do
    case ListCommands.pending(state.document) do
      [] -> state
      pending -> write(state, Enum.reject(pending, &Map.has_key?(state.source_verdicts, elem(&1, 1))), observations)
    end
  end

  defp replay_list_markers(state, _observations), do: state

  defp plan(state, observations) do
    {projections, actions, observations, cache, holds, published, edges} = Reconcile.plan(state, observations)
    {state, health_actions} = AttentionHealth.plan(state, projections)
    actions = health_actions ++ actions
    state = %{state | planned_edges: edges}
    ids = Enum.map(state.document.edges, & &1.prerequisite)
    merged = Enum.reduce(observations, state.merged_at_ms, fn {id, row}, acc -> if row.merged_at_ms, do: Map.put_new(acc, id, row.merged_at_ms), else: acc end)
    state = %{state | closure_cache: cache, holds: holds, published_pr_versions: published, merged_at_ms: Map.take(merged, ids)}
    state = if state.phase == :ready and state.status != :store_unavailable, do: write(state, actions, observations), else: %{state | actions: actions}
    state = if state.phase != :ready and state.status != :store_unavailable, do: Enum.reduce(health_actions, state, &AttentionActions.execute(&2, &1)), else: state
    state = AttentionHealth.store(state)

    holds =
      Enum.reduce(actions, state.holds, fn
        {:begin_withdraw, id}, holds -> MapSet.put(holds, id)
        {:hold_release, id}, holds -> MapSet.delete(holds, id)
        _, holds -> holds
      end)

    retained = for p <- projections, p.state not in [:removed, :completed, :cancelled], do: p.issue_id
    holds = MapSet.intersection(holds, MapSet.new(retained))
    ages = Withdrawal.ages(holds, state.hold_ages, state.clock.(), state.settings.build_queue.reconcile_interval_seconds)
    Reconcile.write_hints(projections, holds, state.document)
    Phoenix.PubSub.broadcast(Aiur.PubSub, "build_queue:changed", {:build_queue_changed, state.status})
    state = %{state | projections: projections, observations: observations, actions: state.actions, holds: holds, hold_ages: ages, reconciles: state.reconciles + 1}
    Progress.publish(state)
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

    AttentionHealth.store(%{
      state
      | document: result.document,
        writer: result.writer,
        write_results: result.write_results,
        status: status,
        actions: actions ++ result.write_attentions,
        intent_reconciles: ages
    })
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

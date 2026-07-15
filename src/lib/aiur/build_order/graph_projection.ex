defmodule Aiur.BuildOrder.GraphProjection do
  @moduledoc """
  Supervised, in-memory catalog and selected-root planning projection.

  Complete `GitHubGraph` candidates are swapped atomically. Provider failures
  update health around the last-known-good generation and never publish a
  partial candidate. Restart deliberately begins unavailable.
  """

  use GenServer

  alias Aiur.BuildOrder.GitHubGraph.Settings
  alias Aiur.BuildOrder.GraphProjection.{Configuration, Failure, Options, Policy, Snapshot, TaskLifecycle}
  alias Aiur.BuildOrder.ProviderHealth
  alias Aiur.TrackerIdentity

  @reset_topic "build_order:graph:reset"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec catalog(GenServer.server()) :: Snapshot.t()
  def catalog(server \\ __MODULE__), do: GenServer.call(server, :catalog)

  @spec selected(GenServer.server(), TrackerIdentity.t()) :: {:ok, Snapshot.t()} | {:error, Failure.t()}
  def selected(server \\ __MODULE__, identity), do: GenServer.call(server, {:selected, identity})

  @spec demand(GenServer.server(), TrackerIdentity.t()) :: {:ok, Snapshot.t()} | {:error, Failure.t()}
  def demand(server \\ __MODULE__, identity), do: GenServer.call(server, {:demand, identity})

  @spec release(GenServer.server(), TrackerIdentity.t()) :: :ok | {:error, Failure.t()}
  def release(server \\ __MODULE__, identity), do: GenServer.call(server, {:release, identity})

  @spec refresh_catalog(GenServer.server()) :: :ok
  def refresh_catalog(server \\ __MODULE__) do
    GenServer.cast(server, :refresh_catalog)
  end

  @spec subscribe_catalog(GenServer.server()) :: :ok | {:error, term()}
  def subscribe_catalog(server \\ __MODULE__) do
    with {:ok, topic} <- GenServer.call(server, :catalog_topic),
         :ok <- Phoenix.PubSub.subscribe(Aiur.PubSub, topic),
         do: Phoenix.PubSub.subscribe(Aiur.PubSub, @reset_topic)
  end

  @spec subscribe_selected(GenServer.server(), TrackerIdentity.t()) :: :ok | {:error, Failure.t() | term()}
  def subscribe_selected(server \\ __MODULE__, identity) do
    with {:ok, topic} <- GenServer.call(server, {:selected_topic, identity}),
         :ok <- Phoenix.PubSub.subscribe(Aiur.PubSub, topic),
         do: Phoenix.PubSub.subscribe(Aiur.PubSub, @reset_topic)
  end

  @spec catalog_topic(TrackerIdentity.repository()) :: String.t()
  defdelegate catalog_topic(repository), to: Policy

  @spec selected_topic(TrackerIdentity.t()) :: String.t()
  defdelegate selected_topic(identity), to: Policy

  @spec reset_topic() :: String.t()
  def reset_topic, do: @reset_topic

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = Options.new(opts)
    subscribe_to_configuration(state)
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_call(:catalog, _from, state) do
    {state, events} = reconcile(state)
    broadcast_all(state, events)
    {:reply, catalog_snapshot(state), state}
  end

  def handle_call({:selected, identity}, _from, state) do
    {state, events} = reconcile(state)
    broadcast_all(state, events)

    case authorize_root(state, identity) do
      {:ok, identity} -> {:reply, {:ok, selected_snapshot(state, identity)}, state}
      {:error, failure} -> {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:demand, identity}, {pid, _tag}, state) do
    {state, events} = reconcile(state)

    case authorize_root(state, identity) do
      {:ok, identity} ->
        case ensure_selected_entry(state, identity) do
          {:ok, state, capacity_events} ->
            {state, identity} = add_demand(state, identity, pid)
            {state, refresh_events} = maybe_refresh_demanded(state, identity)
            events = events ++ capacity_events ++ refresh_events
            broadcast_all(state, events)
            {:reply, {:ok, selected_snapshot(state, identity)}, state}

          {:error, failure} ->
            broadcast_all(state, events)
            {:reply, {:error, failure}, state}
        end

      {:error, failure} ->
        broadcast_all(state, events)
        {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:release, identity}, {pid, _tag}, state) do
    {state, events} = reconcile(state)

    case authorize_root(state, identity) do
      {:ok, identity} ->
        state = remove_demand(state, identity, pid)
        broadcast_all(state, events)
        {:reply, :ok, state}

      {:error, failure} ->
        broadcast_all(state, events)
        {:reply, {:error, failure}, state}
    end
  end

  def handle_call(:catalog_topic, _from, state) do
    {state, events} = reconcile(state)
    broadcast_all(state, events)

    case state.active_repository do
      {_, _} = repository -> {:reply, {:ok, Policy.catalog_topic(repository)}, state}
      _repository -> {:reply, {:error, %Failure{kind: :configuration}}, state}
    end
  end

  def handle_call({:selected_topic, identity}, _from, state) do
    {state, events} = reconcile(state)
    broadcast_all(state, events)

    case authorize_root(state, identity) do
      {:ok, identity} -> {:reply, {:ok, Policy.selected_topic(identity)}, state}
      {:error, failure} -> {:reply, {:error, failure}, state}
    end
  end

  @impl true
  def handle_cast(:refresh_catalog, state) do
    {state, events} = reconcile(state)
    {state, refresh_events} = request_scope(state, :catalog)
    broadcast_all(state, events ++ refresh_events)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    {state, events} = reconcile(state)
    {state, refresh_events} = request_scope(state, :catalog)
    broadcast_all(state, events ++ refresh_events)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {state, events} = complete_task(state, ref, result)
    {state, admitted_events} = admit_pending(state)
    broadcast_all(state, events ++ admitted_events)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) when is_reference(ref) do
    cond do
      Map.has_key?(state.monitor_by_ref, ref) ->
        {:noreply, remove_demand_by_monitor(state, ref, pid)}

      Map.has_key?(state.inflight_by_ref, ref) ->
        {state, events} = complete_task(state, ref, {:error, :transport})
        {state, admitted_events} = admit_pending(state)
        broadcast_all(state, events ++ admitted_events)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:graph_projection_timeout, ref, attempt}, state) do
    case Map.get(state.inflight_by_ref, ref) do
      %{attempt: ^attempt} = inflight ->
        Process.demonitor(ref, [:flush])
        TaskLifecycle.terminate(inflight, state.task_supervisor)
        {state, events} = complete_task(state, ref, {:error, :timeout})
        {state, admitted_events} = admit_pending(state)
        broadcast_all(state, events ++ admitted_events)
        {:noreply, state}

      _inflight ->
        {:noreply, state}
    end
  end

  def handle_info({:graph_projection_due, scope, token}, state) do
    case scope_entry(state, scope) do
      %{timer_token: ^token} = entry ->
        state = put_scope_entry(state, %{entry | timer: nil}, scope)

        if active_scope?(state, scope) do
          {state, events} = request_scope(state, scope)
          broadcast_all(state, events)
          {:noreply, state}
        else
          {:noreply, state}
        end

      _entry ->
        {:noreply, state}
    end
  end

  def handle_info({:workflow_config_updated, generation}, state) do
    {state, events} = reconcile(state, generation)
    {state, refresh_events} = request_scope(state, :catalog)
    broadcast_all(state, events ++ refresh_events)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state
    |> cancel_all_tasks()
    |> cancel_all_timers()

    :ok
  end

  defp reconcile(state, notified_generation \\ nil) do
    case Configuration.snapshot(state, notified_generation) do
      {:ok, snapshot} -> reconcile_snapshot(state, snapshot)
      {:error, :configuration} -> configuration_failed(state)
    end
  end

  defp reconcile_snapshot(%{authority_fingerprint: fingerprint} = state, %{fingerprint: fingerprint} = snapshot)
       when fingerprint != :unknown do
    state =
      state
      |> Map.put(:active_configuration_generation, snapshot.generation)
      |> Map.put(:policy, snapshot.policy)
      |> Map.put(:root_limit, snapshot.limits.root_limit)
      |> Map.put(:page_budget, snapshot.limits.page_budget)
      |> Map.put(:call_budget, snapshot.limits.call_budget)
      |> restore_configuration_health()
      |> enforce_retention_bound()
      |> reschedule_active_scopes()

    {state, []}
  end

  defp reconcile_snapshot(state, snapshot) do
    old_catalog = catalog_snapshot(state)

    state =
      state
      |> cancel_all_tasks()
      |> cancel_all_timers()
      |> clear_demand_monitors()

    now_ms = now_ms(state)

    state = %{
      state
      | catalog: Policy.unavailable_entry(:catalog, now_ms),
        selected: %{},
        pending: MapSet.new(),
        active_repository: snapshot.repository,
        active_configuration_generation: snapshot.generation,
        authority_fingerprint: snapshot.fingerprint,
        authority_generation: state.authority_generation + 1,
        root_limit: snapshot.limits.root_limit,
        page_budget: snapshot.limits.page_budget,
        call_budget: snapshot.limits.call_budget,
        policy: snapshot.policy
    }

    events =
      if old_catalog.repository == :unknown and old_catalog.generation == :unknown,
        do: [{:reset, state.authority_generation}],
        else: [{:health, catalog_snapshot(state)}, {:reset, state.authority_generation}]

    {state, events}
  end

  defp configuration_failed(state) do
    {catalog, catalog_changed?} = fail_configuration(state.catalog, state)

    {selected, selected_events} =
      Enum.reduce(state.selected, {%{}, []}, fn {key, entry}, {entries, events} ->
        {entry, changed?} = fail_configuration(entry, state)
        snapshot = snapshot_for_entry(entry, state)
        {Map.put(entries, key, entry), if(changed?, do: [{:health, snapshot} | events], else: events)}
      end)

    state =
      state
      |> cancel_all_tasks()
      |> cancel_all_timers()
      |> Map.put(:catalog, catalog)
      |> Map.put(:selected, selected)
      |> Map.put(:pending, MapSet.new())

    catalog_events = if(catalog_changed?, do: [{:health, catalog_snapshot(state)}], else: [])
    {state, catalog_events ++ Enum.reverse(selected_events)}
  end

  defp fail_configuration(%{health: %{failure: :configuration}} = entry, _state), do: {entry, false}

  defp fail_configuration(entry, state) do
    entry = Policy.apply_failure(entry, :configuration, now(state), nil, false)
    {entry, true}
  end

  defp restore_configuration_health(state) do
    catalog = restore_entry_configuration_health(state.catalog)
    selected = Map.new(state.selected, fn {key, entry} -> {key, restore_entry_configuration_health(entry)} end)
    %{state | catalog: catalog, selected: selected}
  end

  defp restore_entry_configuration_health(%{health: %ProviderHealth{failure: :configuration}} = entry) do
    state = if(entry.data, do: :stale, else: :unavailable)
    %{entry | health: %{entry.health | state: state, failure: nil, retry_count: 0}}
  end

  defp restore_entry_configuration_health(entry), do: entry

  defp authorize_root(%{active_repository: {_, _} = repository}, identity) do
    case Settings.requested_root(identity, repository) do
      {:ok, identity} -> {:ok, identity}
      {:error, _reason} -> {:error, %Failure{kind: :invalid_root}}
    end
  end

  defp authorize_root(_state, _identity), do: {:error, %Failure{kind: :configuration}}

  defp ensure_selected_entry(state, identity) do
    key = Policy.root_key(identity)

    case Map.fetch(state.selected, key) do
      {:ok, entry} ->
        entry = %{entry | last_access_ms: now_ms(state)}
        {:ok, %{state | selected: Map.put(state.selected, key, entry)}, []}

      :error ->
        with {:ok, state, events} <- make_selected_room(state) do
          entry = Policy.unavailable_entry({:selected, identity}, now_ms(state))
          {:ok, %{state | selected: Map.put(state.selected, key, entry)}, events}
        end
    end
  end

  defp make_selected_room(state) when map_size(state.selected) < state.policy.max_selected_roots,
    do: {:ok, state, []}

  defp make_selected_room(state) do
    case eviction_candidate(state) do
      {key, entry} ->
        state = evict_selected(state, key, entry)
        {:ok, state, [{:health, evicted_snapshot(entry, state)}]}

      nil ->
        {:error, %Failure{kind: :capacity}}
    end
  end

  defp eviction_candidate(state) do
    state.selected
    |> Enum.reject(fn {_key, entry} -> entry.inflight || MapSet.size(entry.demanders) > 0 end)
    |> Enum.min_by(fn {_key, entry} -> entry.last_access_ms end, fn -> nil end)
  end

  defp evict_selected(state, key, entry) do
    cancel_entry_timer(entry)
    %{state | selected: Map.delete(state.selected, key), pending: MapSet.delete(state.pending, entry.scope)}
  end

  defp evicted_snapshot(entry, state) do
    health = ProviderHealth.new(entry.generation, :unavailable, false, failure: :evicted)
    %Snapshot{scope: entry.scope, repository: state.active_repository, generation: entry.generation, health: health}
  end

  defp enforce_retention_bound(state) do
    if map_size(state.selected) <= state.policy.max_selected_roots do
      state
    else
      case eviction_candidate(state) do
        {key, entry} -> state |> evict_selected(key, entry) |> enforce_retention_bound()
        nil -> state
      end
    end
  end

  defp add_demand(state, identity, pid) do
    key = Policy.root_key(identity)
    demand_key = {key, pid}

    if Map.has_key?(state.monitor_by_demand, demand_key) do
      {state, identity}
    else
      ref = Process.monitor(pid)
      entry = Map.fetch!(state.selected, key)
      entry = %{entry | demanders: MapSet.put(entry.demanders, pid), last_access_ms: now_ms(state)}

      state = %{
        state
        | selected: Map.put(state.selected, key, entry),
          monitor_by_ref: Map.put(state.monitor_by_ref, ref, demand_key),
          monitor_by_demand: Map.put(state.monitor_by_demand, demand_key, ref)
      }

      {state, identity}
    end
  end

  defp remove_demand(state, identity, pid) do
    key = Policy.root_key(identity)
    remove_demand_key(state, {key, pid}, true)
  end

  defp remove_demand_by_monitor(state, ref, _pid) do
    case Map.get(state.monitor_by_ref, ref) do
      nil -> state
      demand_key -> remove_demand_key(state, demand_key, false)
    end
  end

  defp remove_demand_key(state, {key, pid} = demand_key, demonitor?) do
    case Map.pop(state.monitor_by_demand, demand_key) do
      {nil, _monitor_by_demand} ->
        state

      {ref, monitor_by_demand} ->
        if demonitor?, do: Process.demonitor(ref, [:flush])

        selected =
          Map.update(state.selected, key, nil, &remove_demander(&1, pid))
          |> Map.reject(fn {_key, entry} -> is_nil(entry) end)

        scope = selected_scope(state, key)
        pending = if(active_scope_in?(selected, key), do: state.pending, else: MapSet.delete(state.pending, scope))

        %{
          state
          | selected: selected,
            pending: pending,
            monitor_by_ref: Map.delete(state.monitor_by_ref, ref),
            monitor_by_demand: monitor_by_demand
        }
    end
  end

  defp remove_demander(entry, pid) do
    entry = %{entry | demanders: MapSet.delete(entry.demanders, pid)}
    if MapSet.size(entry.demanders) == 0, do: cancel_entry_schedule(entry), else: entry
  end

  defp selected_scope(state, key) do
    case Map.get(state.selected, key) do
      %{scope: scope} -> scope
      _entry -> {:selected, nil}
    end
  end

  defp active_scope_in?(selected, key) do
    case Map.get(selected, key) do
      %{demanders: demanders} -> MapSet.size(demanders) > 0
      _entry -> false
    end
  end

  defp maybe_refresh_demanded(state, identity) do
    entry = Map.fetch!(state.selected, Policy.root_key(identity))

    if demand_refresh_due?(entry, state) do
      request_scope(state, entry.scope)
    else
      {schedule_from_success(state, entry.scope), []}
    end
  end

  defp demand_refresh_due?(%{inflight: inflight}, _state) when not is_nil(inflight), do: false

  defp demand_refresh_due?(entry, state) do
    Policy.due?(entry, now_ms(state), state.policy.demand_refresh_ms) and retry_due?(entry, state)
  end

  defp retry_due?(%{health: %{next_retry_at: nil}}, _state), do: true

  defp retry_due?(%{health: %{next_retry_at: next_retry_at}}, state),
    do: DateTime.compare(now(state), next_retry_at) != :lt

  defp request_scope(state, scope) do
    entry = scope_entry(state, scope)

    cond do
      is_nil(entry) ->
        {state, []}

      entry.inflight ->
        {state, []}

      not active_scope?(state, scope) ->
        {state, []}

      map_size(state.inflight_by_ref) >= state.policy.max_inflight ->
        {%{state | pending: MapSet.put(state.pending, scope)}, []}

      true ->
        start_scope(state, entry, scope)
    end
  end

  defp start_scope(state, entry, scope) do
    entry = cancel_entry_schedule(entry)
    now = now(state)
    entry = Policy.refreshing(entry, now)
    attempt = state.next_attempt
    reader_options = reader_options(state)

    case TaskLifecycle.start(state, scope, reader_options) do
      {:ok, task} ->
        timeout_ref =
          Process.send_after(self(), {:graph_projection_timeout, task.ref, attempt}, state.policy.refresh_timeout_ms)

        inflight = %{
          ref: task.ref,
          pid: task.pid,
          timeout_ref: timeout_ref,
          scope: scope,
          attempt: attempt,
          authority_generation: state.authority_generation
        }

        entry = %{entry | inflight: inflight}

        state =
          state
          |> put_scope_entry(entry, scope)
          |> Map.put(:next_attempt, attempt + 1)
          |> Map.put(:inflight_by_ref, Map.put(state.inflight_by_ref, task.ref, inflight))
          |> Map.put(:pending, MapSet.delete(state.pending, scope))

        {state, [{:health, snapshot_for_entry(entry, state)}]}

      :error ->
        fail_scope_start(state, entry, scope, now)
    end
  end

  defp fail_scope_start(state, entry, scope, now) do
    scheduled? = active_scope?(state, scope)
    delay = Policy.retry_delay_ms(entry.health.retry_count, scope_interval(state, scope), nil, now)
    next_retry_at = DateTime.add(now, delay, :millisecond)
    entry = Policy.apply_failure(entry, :transport, now, next_retry_at, scheduled?)
    state = put_scope_entry(state, entry, scope)
    state = if(scheduled?, do: schedule_scope(state, scope, delay), else: state)
    {state, [{:health, snapshot_for_entry(scope_entry(state, scope), state)}]}
  end

  defp complete_task(state, ref, result) do
    case Map.pop(state.inflight_by_ref, ref) do
      {nil, _inflight_by_ref} ->
        {state, []}

      {%{scope: scope} = inflight, inflight_by_ref} ->
        Process.cancel_timer(inflight.timeout_ref)
        state = %{state | inflight_by_ref: inflight_by_ref}
        complete_scope(state, scope, inflight, result)
    end
  end

  defp complete_scope(state, scope, inflight, result) do
    case scope_entry(state, scope) do
      %{inflight: %{ref: ref}} = entry
      when ref == inflight.ref and inflight.authority_generation == state.authority_generation ->
        case Policy.complete_candidate(result, scope, state.active_repository) do
          {:ok, candidate} -> complete_success(state, entry, scope, candidate)
          {:error, failure, provider_result} -> complete_failure(state, entry, scope, failure, provider_result)
        end

      _entry ->
        {state, []}
    end
  end

  defp complete_success(state, entry, scope, candidate) do
    generation = state.next_generation
    entry = Policy.apply_success(entry, candidate, generation, now(state), now_ms(state))
    state = state |> put_scope_entry(entry, scope) |> Map.put(:next_generation, generation + 1)
    state = schedule_after_completion(state, scope, state |> scope_interval(scope))
    {state, [{:generation, snapshot_for_entry(scope_entry(state, scope), state)}]}
  end

  defp complete_failure(state, entry, scope, failure, provider_result) do
    now = now(state)
    scheduled? = active_scope?(state, scope)
    delay = Policy.retry_delay_ms(entry.health.retry_count, scope_interval(state, scope), provider_result, now)
    next_retry_at = DateTime.add(now, delay, :millisecond)
    entry = Policy.apply_failure(entry, failure, now, next_retry_at, scheduled?)
    state = put_scope_entry(state, entry, scope)
    state = if(scheduled?, do: schedule_scope(state, scope, delay), else: state)
    {state, [{:health, snapshot_for_entry(scope_entry(state, scope), state)}]}
  end

  defp admit_pending(state) do
    Enum.reduce_while(state.pending, {state, []}, fn scope, {state, events} ->
      if map_size(state.inflight_by_ref) < state.policy.max_inflight do
        {state, next_events} = request_scope(state, scope)
        {:cont, {state, events ++ next_events}}
      else
        {:halt, {state, events}}
      end
    end)
  end

  defp schedule_after_completion(state, :catalog, delay), do: schedule_scope(state, :catalog, delay)

  defp schedule_after_completion(state, {:selected, _identity} = scope, delay) do
    if active_scope?(state, scope), do: schedule_scope(state, scope, delay), else: state
  end

  defp schedule_from_success(state, scope) do
    entry = scope_entry(state, scope)

    cond do
      is_nil(entry) or not is_nil(entry.inflight) or not is_nil(entry.timer) ->
        state

      is_nil(entry.last_success_ms) ->
        state

      true ->
        remaining = max(0, scope_interval(state, scope) - (now_ms(state) - entry.last_success_ms))
        schedule_scope(state, scope, remaining)
    end
  end

  defp schedule_scope(state, scope, delay) do
    entry = scope_entry(state, scope)
    entry = cancel_entry_schedule(entry)
    token = state.next_timer_token
    timer = Process.send_after(self(), {:graph_projection_due, scope, token}, max(0, delay))
    entry = %{entry | timer: timer, timer_token: token}

    state
    |> put_scope_entry(entry, scope)
    |> Map.put(:next_timer_token, token + 1)
  end

  defp reschedule_active_scopes(state) do
    state = state |> cancel_all_timers() |> schedule_from_success(:catalog)

    Enum.reduce(state.selected, state, fn {_key, entry}, state ->
      if MapSet.size(entry.demanders) > 0, do: schedule_from_success(state, entry.scope), else: state
    end)
  end

  defp active_scope?(_state, :catalog), do: true

  defp active_scope?(state, {:selected, identity}) do
    case Map.get(state.selected, Policy.root_key(identity)) do
      %{demanders: demanders} -> MapSet.size(demanders) > 0
      _entry -> false
    end
  end

  defp scope_interval(state, :catalog), do: state.policy.catalog_refresh_ms
  defp scope_interval(state, {:selected, _identity}), do: state.policy.selected_refresh_ms

  defp scope_entry(state, :catalog), do: state.catalog

  defp scope_entry(state, {:selected, identity}) do
    Map.get(state.selected, Policy.root_key(identity))
  end

  defp put_scope_entry(state, entry, :catalog), do: %{state | catalog: entry}

  defp put_scope_entry(state, entry, {:selected, identity}) do
    %{state | selected: Map.put(state.selected, Policy.root_key(identity), entry)}
  end

  defp catalog_snapshot(state) do
    Policy.snapshot(state.catalog, state.active_repository, now_ms(state), state.policy.catalog_refresh_ms)
  end

  defp selected_snapshot(state, identity) do
    case Map.get(state.selected, Policy.root_key(identity)) do
      nil ->
        identity
        |> then(&Policy.unavailable_entry({:selected, &1}, now_ms(state)))
        |> Policy.snapshot(state.active_repository, now_ms(state), state.policy.selected_refresh_ms)

      entry ->
        Policy.snapshot(entry, state.active_repository, now_ms(state), state.policy.selected_refresh_ms)
    end
  end

  defp snapshot_for_entry(%{scope: :catalog}, state), do: catalog_snapshot(state)
  defp snapshot_for_entry(%{scope: {:selected, identity}}, state), do: selected_snapshot(state, identity)

  defp reader_options(state) do
    [
      repository: state.active_repository,
      root_limit: state.root_limit,
      page_budget: state.page_budget,
      call_budget: state.call_budget
    ]
  end

  defp cancel_all_tasks(state) do
    Enum.each(state.inflight_by_ref, fn {ref, inflight} ->
      Process.demonitor(ref, [:flush])
      TaskLifecycle.terminate(inflight, state.task_supervisor)
    end)

    catalog = %{state.catalog | inflight: nil}
    selected = Map.new(state.selected, fn {key, entry} -> {key, %{entry | inflight: nil}} end)
    %{state | catalog: catalog, selected: selected, inflight_by_ref: %{}}
  end

  defp cancel_all_timers(state) do
    catalog = cancel_entry_schedule(state.catalog)
    selected = Map.new(state.selected, fn {key, entry} -> {key, cancel_entry_schedule(entry)} end)
    %{state | catalog: catalog, selected: selected}
  end

  defp cancel_entry_schedule(%{timer: nil} = entry), do: entry

  defp cancel_entry_schedule(entry) do
    cancel_entry_timer(entry)
    %{entry | timer: nil}
  end

  defp cancel_entry_timer(%{timer: nil}), do: :ok
  defp cancel_entry_timer(%{timer: timer}), do: Process.cancel_timer(timer)

  defp clear_demand_monitors(state) do
    Enum.each(Map.keys(state.monitor_by_ref), &Process.demonitor(&1, [:flush]))
    %{state | monitor_by_ref: %{}, monitor_by_demand: %{}}
  end

  defp broadcast_all(state, events), do: Enum.each(events, &broadcast(state, &1))

  defp broadcast(state, {:reset, generation}) do
    publish(@reset_topic, {:graph_projection_reset, generation})
    after_broadcast(state, {:graph_projection_reset, generation})
  end

  defp broadcast(state, {kind, %Snapshot{} = snapshot}) when kind in [:generation, :health] do
    event =
      case kind do
        :generation -> {:graph_projection_generation, snapshot}
        :health -> {:graph_projection_health, snapshot}
      end

    publish(topic(snapshot), event)
    after_broadcast(state, event)
  end

  defp publish(topic, event) do
    if Process.whereis(Aiur.PubSub), do: Phoenix.PubSub.broadcast(Aiur.PubSub, topic, event)
  end

  defp topic(%Snapshot{scope: :catalog, repository: repository}), do: Policy.catalog_topic(repository)
  defp topic(%Snapshot{scope: {:selected, identity}}), do: Policy.selected_topic(identity)

  defp after_broadcast(state, event) do
    state.after_broadcast.(event)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp subscribe_to_configuration(state) do
    state.configuration_subscriber.(self())
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp now(state), do: state.now.()
  defp now_ms(state), do: state.clock_ms.()
end

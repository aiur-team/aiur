defmodule Aiur.BuildOrder.GraphProjection do
  @moduledoc """
  Supervised, in-memory catalog and selected-root planning projection.

  Complete `GitHubGraph` candidates are swapped atomically. Provider failures
  update health around the last-known-good generation and never publish a
  partial candidate. Restart deliberately begins unavailable.
  """

  use GenServer

  alias Aiur.BuildOrder.{Catalog, ProviderHealth}
  alias Aiur.BuildOrder.GitHubGraph.Settings
  alias Aiur.BuildOrder.GraphProjection.{Configuration, Failure, Options, Policy, Snapshot, TaskLifecycle}
  alias Aiur.TrackerIdentity

  @reset_topic "build_order:graph:reset"

  # How many labelled-read intervals a carried epic/wave count may survive
  # before the columns fall back to "Unresolved". Two gives one missed labelled
  # read of slack without letting a broken labelled cadence publish a number of
  # unbounded age.
  @carry_grace_intervals 2

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

  @doc """
  Registers that the caller is watching `identity`, and returns what is held.

  This costs nothing upstream. It retains the root's entry and enrols the caller
  for broadcasts; it never decides that a read is due. Selecting a root, opening
  the page and holding it open are all this call, so all three are free.

  A caller that genuinely cannot proceed on what is held wants `refresh/2`.
  """
  @spec demand(GenServer.server(), TrackerIdentity.t()) :: {:ok, Snapshot.t()} | {:error, Failure.t()}
  def demand(server \\ __MODULE__, identity), do: GenServer.call(server, {:demand, identity})

  @doc """
  Buys a fresh read of one selected root, because a caller needs one.

  The deliberate counterpart to `demand/2`: this is the only way a selected root
  is read on someone's behalf, and it exists so that removing the viewer cadence
  does not also remove the operator's ability to say "read this now". It is a
  need, stated explicitly by a caller, rather than a cadence inferred from the
  fact that a page is open.

  Asynchronous, and coalesced against any read already inflight for the root, so
  ten callers asking at once still produce one upstream read.
  """
  @spec refresh(GenServer.server(), TrackerIdentity.t()) :: :ok
  def refresh(server \\ __MODULE__, identity) do
    GenServer.cast(server, {:refresh_selected, identity})
  end

  @spec release(GenServer.server(), TrackerIdentity.t()) :: :ok | {:error, Failure.t()}
  def release(server \\ __MODULE__, identity), do: GenServer.call(server, {:release, identity})

  @spec refresh_catalog(GenServer.server()) :: :ok
  def refresh_catalog(server \\ __MODULE__) do
    GenServer.cast(server, :refresh_catalog)
  end

  @spec subscribe_catalog(GenServer.server()) :: :ok | {:error, term()}
  def subscribe_catalog(server \\ __MODULE__) do
    subscribe_scope(fn -> GenServer.call(server, :catalog_topic) end)
  end

  @spec subscribe_selected(GenServer.server(), TrackerIdentity.t()) :: :ok | {:error, Failure.t() | term()}
  def subscribe_selected(server \\ __MODULE__, identity) do
    subscribe_scope(fn -> GenServer.call(server, {:selected_topic, identity}) end)
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
            # Registering demand is bookkeeping, not a request. It records that
            # this pid is watching the root — so the entry is retained and future
            # writes are broadcast to it — and it deliberately buys nothing.
            #
            # This call used to be the page's fetch trigger: selecting a root
            # asked whether `graph_demand_refresh_ms` had elapsed and, on a cold
            # entry, scheduled a read immediately. That made opening the page an
            # upstream cost, and holding it open a recurring one. Both are gone;
            # see `refresh/2` for the path that does spend.
            {state, identity} = add_demand(state, identity, pid)
            events = events ++ capacity_events
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

    if configuration_ready?(state) do
      {:reply, {:ok, Policy.catalog_topic(state.active_repository)}, state}
    else
      {:reply, {:error, %Failure{kind: :configuration}}, state}
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

  # The stated-need path. Unlike the cadence it replaces, it reads only a root
  # somebody is actually holding: an unknown root is not created here, because
  # creating one would let a caller buy a read for a root nothing is watching.
  # `request_scope/2` already declines when a read is inflight, so concurrent
  # callers coalesce onto one.
  def handle_cast({:refresh_selected, identity}, state) do
    {state, events} = reconcile(state)

    {state, refresh_events} =
      with {:ok, identity} <- authorize_root(state, identity),
           %{scope: scope} <- Map.get(state.selected, Policy.root_key(identity)) do
        request_scope(state, scope)
      else
        _not_held -> {state, []}
      end

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
    {state, reconcile_events} = reconcile(state)
    Process.demonitor(ref, [:flush])
    {state, events} = complete_task(state, ref, result)
    {state, admitted_events} = admit_pending(state)
    broadcast_all(state, reconcile_events ++ events ++ admitted_events)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) when is_reference(ref) do
    cond do
      Map.has_key?(state.monitor_by_ref, ref) ->
        {:noreply, remove_demand_by_monitor(state, ref, pid)}

      Map.has_key?(state.inflight_by_ref, ref) ->
        {state, reconcile_events} = reconcile(state)
        {state, events} = complete_task(state, ref, {:error, :transport})
        {state, admitted_events} = admit_pending(state)
        broadcast_all(state, reconcile_events ++ events ++ admitted_events)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:graph_projection_timeout, ref, attempt}, state) do
    {state, reconcile_events} = reconcile(state)

    case Map.get(state.inflight_by_ref, ref) do
      %{attempt: ^attempt} = inflight ->
        Process.demonitor(ref, [:flush])
        TaskLifecycle.terminate(inflight, state.task_supervisor)
        {state, events} = complete_task(state, ref, {:error, :timeout})
        {state, admitted_events} = admit_pending(state)
        broadcast_all(state, reconcile_events ++ events ++ admitted_events)
        {:noreply, state}

      _inflight ->
        broadcast_all(state, reconcile_events)
        {:noreply, state}
    end
  end

  def handle_info({:graph_projection_due, scope, token}, state) do
    case scope_entry(state, scope) do
      %{timer_token: ^token} = entry ->
        state = put_scope_entry(state, %{entry | timer: nil}, scope)
        {state, reconcile_events} = reconcile(state)

        if active_scope?(state, scope) do
          {state, events} = request_scope(state, scope)
          broadcast_all(state, reconcile_events ++ events)
          {:noreply, state}
        else
          broadcast_all(state, reconcile_events)
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
        # A new authority discards the catalog entirely, so the counts it
        # carried are gone too. Clearing the stamp makes the first read under
        # the new authority a labelled one.
        catalog_labels_read_ms: nil,
        catalog_labels_ok_ms: nil,
        catalog_labels_failures: 0,
        catalog_labels_penalty_ms: 0,
        selected: %{},
        # Cleared with the roots they describe. A marker that outlived its graph
        # would tell the next read of that root it was already current when
        # nothing is held for it — and across repeated authority changes the map
        # would grow without bound.
        selected_fingerprints: %{},
        pending: MapSet.new(),
        active_repository: snapshot.repository,
        active_configuration_generation: snapshot.generation,
        authority_fingerprint: snapshot.fingerprint,
        authority_epoch: new_authority_epoch(),
        authority_generation: state.authority_generation + 1,
        root_limit: snapshot.limits.root_limit,
        page_budget: snapshot.limits.page_budget,
        call_budget: snapshot.limits.call_budget,
        policy: snapshot.policy
    }

    events =
      if old_catalog.repository == :unknown and old_catalog.generation == :unknown,
        do: [{:reset, state.authority_epoch}],
        else: [{:health, catalog_snapshot(state)}, {:reset, state.authority_epoch}]

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

  defp authorize_root(%{catalog: %{health: %{failure: :configuration}}}, _identity),
    do: {:error, %Failure{kind: :configuration}}

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

    %{
      state
      | selected: Map.delete(state.selected, key),
        # The marker describes a graph this process no longer holds. Keeping it
        # would tell a later re-selection of the same root that it was already
        # current when it holds nothing at all.
        selected_fingerprints: Map.delete(state.selected_fingerprints, key),
        pending: MapSet.delete(state.pending, entry.scope)
    }
  end

  defp evicted_snapshot(entry, state) do
    health = ProviderHealth.new(entry.generation, :unavailable, false, failure: :evicted)

    %Snapshot{
      scope: entry.scope,
      repository: state.active_repository,
      authority_epoch: state.authority_epoch,
      generation: entry.generation,
      health: health
    }
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

  defp retry_due?(%{health: %{next_retry_at: nil}}, _state), do: true

  defp retry_due?(%{health: %{next_retry_at: next_retry_at}}, state),
    do: DateTime.compare(now(state), next_retry_at) != :lt

  defp request_scope(state, scope) do
    entry = scope_entry(state, scope)

    cond do
      not configuration_ready?(state) ->
        {state, []}

      is_nil(entry) ->
        {state, []}

      # A read is already running. Whether that satisfies this request depends on
      # *which world it is reading*, so the two cases are separated rather than
      # both being dropped.
      #
      # Same marker: the inflight read was dispatched against the catalog
      # observation this request is about, so it will answer it. Coalesce — this
      # is what makes ten simultaneous callers produce one read.
      #
      # Different marker: the inflight read was dispatched against an older
      # catalog and cannot answer this request, so dropping it is a lost update —
      # the read lands, stamps its own (older) marker, and nothing is left to
      # notice the newer one. Queue it; `admit_pending/1` starts it as soon as the
      # inflight read finishes.
      entry.inflight ->
        if inflight_satisfies?(entry.inflight, state, scope),
          do: {state, []},
          else: {%{state | pending: MapSet.put(state.pending, scope)}, []}

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
    member_labels? = catalog_labels_due?(state, scope)
    reader_options = reader_options(state, member_labels?)

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
          member_labels?: member_labels?,
          # The catalog marker in force when this read was *dispatched*, not when
          # it lands. Stamping the completion-time marker is a lost update: a read
          # dispatched against F1 can complete after a catalog cycle has published
          # F2, and stamping F2 onto F1-era data marks the root current at a state
          # it has never held — after which nothing ever re-reads it.
          catalog_fingerprint: requested_fingerprint(state, scope),
          authority_generation: state.authority_generation,
          configuration_generation: state.active_configuration_generation
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
      when ref == inflight.ref and inflight.authority_generation == state.authority_generation and
             inflight.configuration_generation == state.active_configuration_generation ->
        case Policy.complete_candidate(result, scope, state.active_repository) do
          {:ok, candidate} ->
            complete_success(state, entry, scope, candidate, inflight)

          {:error, failure, provider_result} ->
            state
            |> record_catalog_labels_failure(scope, inflight)
            |> complete_failure(entry, scope, failure, provider_result)
        end

      _entry ->
        discard_obsolete_completion(state, scope, inflight.ref)
    end
  end

  defp discard_obsolete_completion(state, scope, ref) do
    case scope_entry(state, scope) do
      %{inflight: %{ref: ^ref}} = entry ->
        entry = %{entry | inflight: nil, health: %{entry.health | refreshing?: false}}
        state = put_scope_entry(state, entry, scope)
        request_scope(state, scope)

      _entry ->
        {state, []}
    end
  end

  defp complete_success(state, entry, scope, candidate, inflight) do
    generation = state.next_generation
    candidate = carry_catalog_counts(state, candidate, entry, scope, inflight)
    entry = Policy.apply_success(entry, candidate, generation, now(state), now_ms(state))

    state =
      state
      |> put_scope_entry(entry, scope)
      |> Map.put(:next_generation, generation + 1)
      |> record_catalog_labels_read(scope, inflight)

    state = schedule_after_completion(state, scope, state |> scope_interval(scope))
    state = record_selected_fingerprint(state, scope, inflight)
    events = [{:generation, snapshot_for_entry(scope_entry(state, scope), state)}]

    {state, follow_up} = request_changed_selected_roots(state, scope)
    {state, events ++ follow_up}
  end

  # A selected root's graph is read because the catalog — the one daemon-owned
  # reader left — says the root moved, or because nothing has ever been read for
  # a root somebody is watching. Both are writer-driven: neither depends on how
  # long a page stays open, and neither repeats while the root sits still.
  #
  # Only a *catalog* completion reaches this. A selected completion must not, or
  # a root would refresh itself forever.
  defp request_changed_selected_roots(state, :catalog) do
    state.selected
    |> Enum.filter(fn {_key, entry} -> selected_read_due?(state, entry) end)
    |> Enum.reduce({state, []}, fn {_key, entry}, {state, events} ->
      {state, next_events} = request_scope(state, entry.scope)
      {state, events ++ next_events}
    end)
  end

  defp request_changed_selected_roots(state, _scope), do: {state, []}

  # "Is anybody watching?" is deliberately not asked here. `request_scope/2`
  # already declines a scope that is not active, and for a selected root that
  # means `demanders` is empty — so a root that was selected and then released
  # keeps its entry and buys nothing. Repeating the check here would be a second
  # copy of that rule, free to drift from the one that is actually enforced.
  defp selected_read_due?(state, entry) do
    cond do
      # A demanded root that has never been read is the cold case. It is bought
      # once, on the catalog's cycle rather than on the viewer's, and it does not
      # repeat once it succeeds. Backoff still applies, so a root that fails to
      # read does not retry on every catalog poll.
      is_nil(entry.data) -> retry_due?(entry, state)
      # Otherwise: only a root the catalog says has moved.
      selected_fingerprint_moved?(state, entry) -> retry_due?(entry, state)
      true -> false
    end
  end

  # `nil` on either side means "no comparable marker", which is not evidence of
  # change. Treating it as change would make every catalog poll re-read every
  # watched root — the deleted cadence back again, wearing the writer's clothes.
  defp selected_fingerprint_moved?(state, %{scope: {:selected, identity}}) do
    case {catalog_fingerprint(state, identity), Map.get(state.selected_fingerprints, Policy.root_key(identity))} do
      {nil, _recorded} -> false
      {_current, nil} -> false
      {current, recorded} -> current != recorded
    end
  end

  defp selected_fingerprint_moved?(_state, _entry), do: false

  defp catalog_fingerprint(%{catalog: %{data: %Catalog{} = catalog}}, identity),
    do: Catalog.root_fingerprint(catalog, identity)

  defp catalog_fingerprint(_state, _identity), do: nil

  # Stamped from the marker captured when the read was dispatched, carried on the
  # inflight record. It records which catalog observation this graph actually
  # corresponds to, which is the only claim the data supports.
  defp record_selected_fingerprint(state, {:selected, identity}, inflight) do
    key = Policy.root_key(identity)

    case Map.get(inflight, :catalog_fingerprint) do
      nil -> %{state | selected_fingerprints: Map.delete(state.selected_fingerprints, key)}
      fingerprint -> %{state | selected_fingerprints: Map.put(state.selected_fingerprints, key, fingerprint)}
    end
  end

  defp record_selected_fingerprint(state, _scope, _inflight), do: state

  defp requested_fingerprint(state, {:selected, identity}), do: catalog_fingerprint(state, identity)
  defp requested_fingerprint(_state, _scope), do: nil

  defp inflight_satisfies?(inflight, state, scope) do
    Map.get(inflight, :catalog_fingerprint) == requested_fingerprint(state, scope)
  end

  # An unlabelled catalog poll cannot resolve epic/wave counts, so it inherits
  # the previous generation's — but only for roots `Catalog.carry_forward_counts/2`
  # can match, and only while the labelled cadence is actually keeping up.
  #
  # A *labelled* read is authoritative: if it read the member labels and still
  # could not resolve a count, the honest answer is "Unresolved", not the number
  # from before. Inheriting there would let one stale count survive every
  # expensive refresh that was supposed to correct it.
  defp carry_catalog_counts(state, %Catalog{} = candidate, %{data: %Catalog{} = previous}, :catalog, inflight) do
    if labelled_read?(inflight) or carry_expired?(state) do
      candidate
    else
      Catalog.carry_forward_counts(candidate, previous)
    end
  end

  defp carry_catalog_counts(_state, candidate, _entry, _scope, _inflight), do: candidate

  defp labelled_read?(%{member_labels?: true}), do: true
  defp labelled_read?(_inflight), do: false

  # Carrying is a bridge between labelled reads, not a substitute for them. If
  # the labelled read has been failing for longer than the grace window, the
  # counts are no longer a number we can stand behind, so the columns fall back
  # to "Unresolved" rather than asserting an unbounded-age figure.
  defp carry_expired?(%{catalog_labels_ok_ms: nil}), do: false

  defp carry_expired?(%{catalog_labels_ok_ms: ok_ms} = state),
    do: now_ms(state) - ok_ms > state.policy.catalog_labels_refresh_ms * @carry_grace_intervals

  # The cadence is stamped on success, not on dispatch: a labelled read that
  # failed bought nothing, so it must not push the next one out by a full
  # interval. It must not retry immediately either — a labelled read that fails
  # deterministically (a timeout on the much larger response, a node-limit
  # rejection, point exhaustion) would otherwise make *every* catalog poll buy
  # the expensive query, which is exactly the budget burn #1766 is about. So a
  # failed labelled read backs off geometrically, and the cheap reads in between
  # keep the catalog publishing.
  defp record_catalog_labels_read(state, :catalog, %{member_labels?: true}) do
    now_ms = now_ms(state)

    %{
      state
      | catalog_labels_read_ms: now_ms,
        catalog_labels_ok_ms: now_ms,
        catalog_labels_penalty_ms: 0,
        catalog_labels_failures: 0
    }
  end

  defp record_catalog_labels_read(state, _scope, _inflight), do: state

  defp record_catalog_labels_failure(state, :catalog, %{member_labels?: true}) do
    failures = state.catalog_labels_failures + 1

    %{
      state
      | catalog_labels_read_ms: now_ms(state),
        catalog_labels_failures: failures,
        catalog_labels_penalty_ms: labels_penalty_ms(state, failures)
    }
  end

  defp record_catalog_labels_failure(state, _scope, _inflight), do: state

  defp labels_penalty_ms(state, failures) do
    backoff = state.policy.catalog_refresh_ms * Integer.pow(2, min(failures - 1, 16))
    min(backoff, state.policy.catalog_labels_refresh_ms)
  end

  defp complete_failure(state, entry, scope, failure, provider_result) do
    now = now(state)
    scheduled? = active_scope?(state, scope)
    delay = Policy.retry_delay_ms(entry.health.retry_count, scope_interval(state, scope), provider_result, now)
    next_retry_at = DateTime.add(now, delay, :millisecond)
    entry = Policy.apply_failure(entry, failure, now, next_retry_at, true)
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

  # A selected root never schedules its successor. Completing a read used to
  # queue the next one `graph_selected_refresh_ms` later for as long as anyone
  # was watching, which made an open page a permanent meter — the single most
  # expensive read in Build Order, repeating because of who was looking rather
  # than because anything had changed.
  #
  # What refreshes a selected root now is the daemon's own catalog reconciliation,
  # via the per-root change marker, plus an explicit `refresh/2`. Neither depends
  # on a viewer. A webhook or mutation write to `Aiur.GitHub.ResourceStore` does
  # *not* reach here — the store holds issues, not graphs — so it is not claimed.
  defp schedule_after_completion(state, {:selected, _identity}, _delay), do: state

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

  defp schedule_active_scope(state, scope) do
    entry = scope_entry(state, scope)

    cond do
      not configuration_ready?(state) or is_nil(entry) or not active_scope?(state, scope) or
        not is_nil(entry.inflight) or not is_nil(entry.timer) ->
        state

      is_nil(entry.health.next_retry_at) ->
        schedule_from_success(state, scope)

      retry_due?(entry, state) ->
        schedule_scope(state, scope, 0)

      true ->
        delay = max(0, DateTime.diff(entry.health.next_retry_at, now(state), :millisecond))
        schedule_scope(state, scope, delay)
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

  # Only the catalog gets a *cadence* restored here. A selected root has none any
  # more, so re-arming one for every watched root — which is what this used to do
  # — would quietly reintroduce the viewer-driven refresh that
  # `schedule_after_completion/3` removes.
  #
  # A selected root's **retry** is a different thing and must survive, because
  # this runs on almost every message: it cancels all timers, so without
  # restoring the retry a root whose read failed would lose its backoff timer to
  # the next unrelated message and never be read again. So a selected scope is
  # re-armed exactly when it is holding a pending retry, and never otherwise.
  defp reschedule_active_scopes(state) do
    state
    |> cancel_all_timers()
    |> schedule_active_scope(:catalog)
    |> restore_selected_retries()
  end

  defp restore_selected_retries(state) do
    Enum.reduce(state.selected, state, fn {_key, entry}, state ->
      if is_nil(entry.health.next_retry_at),
        do: state,
        else: schedule_active_scope(state, entry.scope)
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

  # A selected root has no refresh interval of its own any more. What remains for
  # it are the two things an interval was still being read for — the base of the
  # failure backoff, and the window after which a snapshot is shown as ageing —
  # and for both the honest number is the catalog cadence: the catalog
  # reconciliation is the daemon-owned writer that would next notice this root
  # changing, so it is the real bound on how stale the root can be without
  # anyone finding out.
  defp scope_interval(state, {:selected, _identity}), do: state.policy.catalog_refresh_ms

  defp scope_entry(state, :catalog), do: state.catalog

  defp scope_entry(state, {:selected, identity}) do
    Map.get(state.selected, Policy.root_key(identity))
  end

  defp put_scope_entry(state, entry, :catalog), do: %{state | catalog: entry}

  defp put_scope_entry(state, entry, {:selected, identity}) do
    %{state | selected: Map.put(state.selected, Policy.root_key(identity), entry)}
  end

  defp catalog_snapshot(state) do
    Policy.snapshot(
      state.catalog,
      state.active_repository,
      state.authority_epoch,
      now_ms(state),
      state.policy.catalog_refresh_ms
    )
  end

  # The window after which a selected root is *displayed* as ageing. It is not a
  # refresh trigger — nothing reads this to decide whether to spend — it only
  # decides what the page tells the operator about the age of what it is showing.
  defp selected_staleness_ms(state), do: state.policy.catalog_refresh_ms

  defp selected_snapshot(state, identity) do
    case Map.get(state.selected, Policy.root_key(identity)) do
      nil ->
        identity
        |> then(&Policy.unavailable_entry({:selected, &1}, now_ms(state)))
        |> Policy.snapshot(state.active_repository, state.authority_epoch, now_ms(state), selected_staleness_ms(state))

      entry ->
        Policy.snapshot(entry, state.active_repository, state.authority_epoch, now_ms(state), selected_staleness_ms(state))
    end
  end

  defp snapshot_for_entry(%{scope: :catalog}, state), do: catalog_snapshot(state)
  defp snapshot_for_entry(%{scope: {:selected, identity}}, state), do: selected_snapshot(state, identity)

  defp reader_options(state, member_labels?) do
    [
      repository: state.active_repository,
      root_limit: state.root_limit,
      page_budget: state.page_budget,
      call_budget: state.call_budget,
      member_labels: member_labels?
    ]
  end

  # Only the catalog has a labelled variant, and it is bought on its own slow
  # cadence because the per-member `labels` connection costs ~26 GraphQL points
  # against a 5,000-points/hour budget versus ~1 without it (#1766). The first
  # read under an authority is always labelled so the page resolves promptly;
  # after that the cheap reads carry the resolved counts forward.
  defp catalog_labels_due?(_state, {:selected, _identity}), do: false
  defp catalog_labels_due?(%{catalog_labels_read_ms: nil}, :catalog), do: true

  defp catalog_labels_due?(%{catalog_labels_read_ms: last_ms} = state, :catalog),
    do: now_ms(state) - last_ms >= labels_interval_ms(state)

  # After a failed labelled read the gate is the backoff penalty, not the full
  # cadence, so a transient failure costs one poll rather than ten minutes of
  # unresolved counts — while a persistent one still backs off to the cadence.
  defp labels_interval_ms(%{catalog_labels_penalty_ms: penalty}) when is_integer(penalty) and penalty > 0, do: penalty
  defp labels_interval_ms(state), do: state.policy.catalog_labels_refresh_ms

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

  defp subscribe_scope(topic_fun) do
    with :ok <- Phoenix.PubSub.subscribe(Aiur.PubSub, @reset_topic),
         {:ok, topic} <- topic_fun.() do
      Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
    end
  end

  defp configuration_ready?(%{active_repository: {_, _}, authority_fingerprint: fingerprint, catalog: catalog}) do
    fingerprint != :unknown and catalog.health.failure != :configuration
  end

  defp configuration_ready?(_state), do: false

  defp now(state), do: state.now.()
  defp now_ms(state), do: state.clock_ms.()
  defp new_authority_epoch, do: System.unique_integer([:positive, :monotonic])
end

defmodule Aiur.BuildOrder.GraphProjection do
  @moduledoc """
  Supervised, in-memory catalog and selected-root planning projection.

  Complete `GitHubGraph` candidates are swapped atomically. Provider failures
  update health around the last-known-good generation and never publish a
  partial candidate. Restart deliberately begins unavailable.
  """

  use GenServer

  alias Aiur.BuildOrder.GraphProjection.{
    Authority,
    CapabilityReader,
    Demand,
    Failure,
    Options,
    Policy,
    Publication,
    Reads,
    Reconciliation,
    ReconciliationTimer,
    Resources,
    Schedule,
    Snapshot,
    TaskLifecycle
  }

  alias Aiur.TrackerIdentity

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
  ten callers asking at once still produce one upstream read. It does not ask
  whether a page happens to be registered on the root: a stated need is answered
  for any root the projection holds (#2538).
  """
  @spec refresh(GenServer.server(), TrackerIdentity.t()) :: :ok
  def refresh(server \\ __MODULE__, identity) do
    GenServer.cast(server, {:refresh_selected, identity})
  end

  @doc """
  Whether a caller holding `snapshot` may ask for another read at `now`.

  `refresh/2` is a stated need and does not consult backoff, so a caller that
  asks on every poll uses this to avoid restarting a read that has just failed
  or that the provider asked to be retried later. It is the same rule the
  projection applies to its own retries.
  """
  @spec read_due?(Snapshot.t(), DateTime.t()) :: boolean()
  def read_due?(%Snapshot{health: health}, %DateTime{} = now), do: Policy.retry_due?(health, now)

  @spec release(GenServer.server(), TrackerIdentity.t()) :: :ok | {:error, Failure.t()}
  def release(server \\ __MODULE__, identity), do: GenServer.call(server, {:release, identity})

  @doc """
  Re-converges the Build Order catalog, because an operator asked for it.

  This buys the GraphQL re-converge as well as the rebuild from the store. The
  store is fed by `sub_issues` / `issue_dependencies` deliveries, so on a repo
  with no webhooks configured a store-only rebuild republishes the boot-time
  world for ever — the defect this call exists to be an escape from (#2538).

  Asynchronous, and coalesced: a re-converge already running is not joined by a
  second one.
  """
  @spec refresh_catalog(GenServer.server()) :: :ok
  def refresh_catalog(server \\ __MODULE__) do
    GenServer.cast(server, :refresh_catalog)
  end

  @spec subscribe_catalog(GenServer.server()) :: :ok | {:error, term()}
  def subscribe_catalog(server \\ __MODULE__) do
    Publication.subscribe_scope(fn -> GenServer.call(server, :catalog_topic) end)
  end

  @spec subscribe_selected(GenServer.server(), TrackerIdentity.t()) :: :ok | {:error, Failure.t() | term()}
  def subscribe_selected(server \\ __MODULE__, identity) do
    Publication.subscribe_scope(fn -> GenServer.call(server, {:selected_topic, identity}) end)
  end

  @spec catalog_topic(TrackerIdentity.repository()) :: String.t()
  defdelegate catalog_topic(repository), to: Policy

  @spec selected_topic(TrackerIdentity.t()) :: String.t()
  defdelegate selected_topic(identity), to: Policy

  @spec reset_topic() :: String.t()
  defdelegate reset_topic(), to: Publication

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = Options.new(opts) |> tap(&CapabilityReader.publish(&1, Schedule.catalog_bound_ms(&1)))
    subscribe_to_configuration(state)
    subscribe_to_resources(state)
    subscribe_to_mode_events(state)
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_call(:catalog, _from, state) do
    {state, events} = Authority.reconcile(state)
    Publication.broadcast_all(state, events)
    {:reply, Publication.catalog_snapshot(state), state}
  end

  def handle_call({:selected, identity}, _from, state) do
    {state, events} = Authority.reconcile(state)
    Publication.broadcast_all(state, events)

    case Authority.authorize_root(state, identity) do
      {:ok, identity} -> {:reply, {:ok, Publication.selected_snapshot(state, identity)}, state}
      {:error, failure} -> {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:demand, identity}, {pid, _tag}, state) do
    {state, events} = Authority.reconcile(state)

    case Authority.authorize_root(state, identity) do
      {:ok, identity} ->
        case Demand.ensure_selected_entry(state, identity) do
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
            {state, identity} = Demand.add_demand(state, identity, pid)
            {state, due_events} = Demand.request_superseded_demand(state, identity)
            events = events ++ capacity_events ++ due_events
            Publication.broadcast_all(state, events)
            {:reply, {:ok, Publication.selected_snapshot(state, identity)}, state}

          {:error, failure} ->
            Publication.broadcast_all(state, events)
            {:reply, {:error, failure}, state}
        end

      {:error, failure} ->
        Publication.broadcast_all(state, events)
        {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:release, identity}, {pid, _tag}, state) do
    {state, events} = Authority.reconcile(state)

    case Authority.authorize_root(state, identity) do
      {:ok, identity} ->
        state = Demand.remove_demand(state, identity, pid)
        Publication.broadcast_all(state, events)
        {:reply, :ok, state}

      {:error, failure} ->
        Publication.broadcast_all(state, events)
        {:reply, {:error, failure}, state}
    end
  end

  def handle_call(:catalog_topic, _from, state) do
    {state, events} = Authority.reconcile(state)
    Publication.broadcast_all(state, events)

    if Schedule.configuration_ready?(state) do
      {:reply, {:ok, Policy.catalog_topic(state.active_repository)}, state}
    else
      {:reply, {:error, %Failure{kind: :configuration}}, state}
    end
  end

  def handle_call({:selected_topic, identity}, _from, state) do
    {state, events} = Authority.reconcile(state)
    Publication.broadcast_all(state, events)

    case Authority.authorize_root(state, identity) do
      {:ok, identity} -> {:reply, {:ok, Policy.selected_topic(identity)}, state}
      {:error, failure} -> {:reply, {:error, failure}, state}
    end
  end

  @impl true
  # An operator saying "read this now". The catalog is event-sourced from the
  # store, so a store-only rebuild republishes exactly what the deliveries have
  # already deposited — on a repo with no webhooks configured, that is nothing
  # written since boot, and the catalog reports `member_count: 0` for a root
  # whose sub-issues exist on GitHub (#2538). So the explicit refresh buys the
  # re-converge from GitHub as well, and the store rebuild it also requests
  # publishes again when the reconciliation's deposits land.
  #
  # `start_reconciliation/1` declines while one is inflight, so ten operators
  # refreshing at once still produce one GraphQL re-converge. There is
  # deliberately no cooldown gate here: the cooldown exists to stop a *degraded*
  # repo re-converging on every store event, and this path is not an event.
  def handle_cast(:refresh_catalog, state) do
    {state, events} = Authority.reconcile(state)
    state = state |> Reconciliation.start_reconciliation() |> ReconciliationTimer.arm()
    {state, refresh_events} = Reads.request_scope(state, :catalog)
    Publication.broadcast_all(state, events ++ refresh_events)
    {:noreply, state}
  end

  # The stated-need path. Unlike the cadence it replaces, it reads only a root
  # somebody is actually holding: an unknown root is not created here, because
  # creating one would let a caller buy a read for a root nothing is watching.
  # The request is `force?`: it is answered for any root the projection holds,
  # not only one a page is currently registered on. Whether anyone is watching
  # is the question for a request the daemon *inferred*; this one was stated
  # (#2538). The inflight and `max_inflight` rules still hold, so concurrent
  # callers still coalesce onto one read.
  def handle_cast({:refresh_selected, identity}, state) do
    {state, events} = Authority.reconcile(state)

    {state, refresh_events} =
      with {:ok, identity} <- Authority.authorize_root(state, identity),
           %{scope: scope} <- Map.get(state.selected, Policy.root_key(identity)) do
        Reads.request_scope(state, scope, force?: true)
      else
        _not_held -> {state, []}
      end

    Publication.broadcast_all(state, events ++ refresh_events)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    {state, events} = Authority.reconcile(state)

    # Boot reconcile: re-converge the event-sourced store from GitHub, then
    # rebuild the catalog from the store's own change events. This is the rare
    # reconciliation; a bounded safety timer also covers missing deliveries.
    # The first catalog rebuild is requested here too, so the page has a
    # (possibly empty) snapshot before the reconciliation lands; the
    # reconciliation's deposits and `clear/3` publication then wake the rebuild
    # that replaces it.
    state = state |> Reconciliation.start_reconciliation() |> ReconciliationTimer.arm()
    {state, refresh_events} = Reads.request_scope(state, :catalog)
    Publication.broadcast_all(state, events ++ refresh_events)
    {:noreply, state}
  end

  # An otherwise healthy webhook stream can omit an entire event family.
  # Reconcile membership on a daemon-owned bound, even without store events.
  def handle_info({:reconcile_membership, token}, %{reconciliation_timer: %{token: token}} = state) do
    {state, events} = Authority.reconcile(state)
    state = %{state | reconciliation_timer: nil}

    state =
      if state.active_repository != nil and is_nil(state.reconciliation) and Reconciliation.reconciliation_due?(state),
        do: Reconciliation.start_reconciliation(state),
        else: state

    Publication.broadcast_all(state, events)
    {:noreply, ReconciliationTimer.arm(state)}
  end

  def handle_info({:reconcile_membership, _stale_token}, state), do: {:noreply, state}

  # A webhook-backed repo degraded: deliveries are being dropped, so the
  # event-sourced store cannot converge on its own and the rare reconciliation
  # is owed. Only the active repo's degradation matters.
  def handle_info({:webhook_mode_changed, %{repo: repo, state: :degraded}}, state) do
    {state, reconcile_events} = Authority.reconcile(state)

    state =
      if Resources.repository_match?(state, repo) do
        Reconciliation.start_reconciliation(state)
      else
        state
      end

    Publication.broadcast_all(state, reconcile_events)
    {:noreply, state}
  end

  # The event-sourced catalog's wake-up: a delivery or Aiur-originated mutation
  # changed one of the resource types the catalog is projected from, so rebuild
  # the catalog from the store. This replaces the old periodic catalog poll.
  # A dependency-edge change additionally re-reads any watched root it touches,
  # so a blocked-by relationship set outside Aiur reflects on the page without
  # a `build_order_catalog` call (#2313).
  def handle_info({:github_resource_changed, change}, state) do
    {state, reconcile_events} = Authority.reconcile(state)
    state = Reconciliation.maybe_reconcile_degraded(state)
    {state, events} = Resources.on_resource_change(state, change)
    Publication.broadcast_all(state, reconcile_events ++ events)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    {state, reconcile_events} = Authority.reconcile(state)

    case state.reconciliation do
      %{ref: ^ref} ->
        # The reconciliation's deposits and its `clear/3` publication already
        # published store changes, which is what rebuilds the catalog from the
        # converged store. Nothing to do here beyond clearing the inflight
        # marker; an already-converged reconciliation changed nothing, so a
        # rebuild would be a no-op anyway.
        state = ReconciliationTimer.arm(%{state | reconciliation: nil, last_reconciliation_ms: Schedule.now_ms(state)})
        Publication.broadcast_all(state, reconcile_events)
        {:noreply, state}

      _other ->
        Process.demonitor(ref, [:flush])
        {state, events} = Reads.complete_task(state, ref, result)
        {state, admitted_events} = Reads.admit_pending(state)
        Publication.broadcast_all(state, reconcile_events ++ events ++ admitted_events)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) when is_reference(ref) do
    cond do
      Map.has_key?(state.monitor_by_ref, ref) ->
        {:noreply, Demand.remove_demand_by_monitor(state, ref, pid)}

      match?(%{ref: ^ref}, state.reconciliation) ->
        state = %{state | reconciliation: nil}
        Publication.broadcast_all(state, [])
        {:noreply, state}

      Map.has_key?(state.inflight_by_ref, ref) ->
        {state, reconcile_events} = Authority.reconcile(state)
        {state, events} = Reads.complete_task(state, ref, {:error, :transport})
        {state, admitted_events} = Reads.admit_pending(state)
        Publication.broadcast_all(state, reconcile_events ++ events ++ admitted_events)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:graph_projection_timeout, ref, attempt}, state) do
    {state, reconcile_events} = Authority.reconcile(state)

    case Map.get(state.inflight_by_ref, ref) do
      %{attempt: ^attempt} = inflight ->
        Process.demonitor(ref, [:flush])
        TaskLifecycle.terminate(inflight, state.task_supervisor)
        {state, events} = Reads.complete_task(state, ref, {:error, :timeout})
        {state, admitted_events} = Reads.admit_pending(state)
        Publication.broadcast_all(state, reconcile_events ++ events ++ admitted_events)
        {:noreply, state}

      _inflight ->
        Publication.broadcast_all(state, reconcile_events)
        {:noreply, state}
    end
  end

  def handle_info({:graph_projection_due, scope, token}, state) do
    case Schedule.scope_entry(state, scope) do
      %{timer_token: ^token} = entry ->
        state = Schedule.put_scope_entry(state, %{entry | timer: nil}, scope)
        {state, reconcile_events} = Authority.reconcile(state)

        if Schedule.active_scope?(state, scope) do
          {state, events} = Reads.request_scope(state, scope)
          Publication.broadcast_all(state, reconcile_events ++ events)
          {:noreply, state}
        else
          Publication.broadcast_all(state, reconcile_events)
          {:noreply, state}
        end

      _entry ->
        {:noreply, state}
    end
  end

  def handle_info({:graph_projection_member_due, key, token}, state) do
    case Map.get(state.member_due, key) do
      %{token: ^token} ->
        state = %{state | member_due: Map.delete(state.member_due, key)}
        {state, reconcile_events} = Authority.reconcile(state)
        {state, events} = Resources.request_member_due(state, key)
        Publication.broadcast_all(state, reconcile_events ++ events)
        {:noreply, state}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:workflow_config_updated, generation}, state) do
    {state, events} = Authority.reconcile(state, generation)
    {state, refresh_events} = Reads.request_scope(state, :catalog)
    Publication.broadcast_all(state, events ++ refresh_events)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state
    |> ReconciliationTimer.cancel()
    |> Reconciliation.cancel_reconciliation()
    |> Reads.cancel_all_tasks()
    |> Schedule.cancel_all_timers()

    :ok
  end

  defp subscribe_to_configuration(state) do
    state.configuration_subscriber.(self())
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Subscribes the projection to the resource types the catalog is projected
  # from, so a webhook delivery or Aiur-originated mutation that changes one
  # wakes a rebuild from the store instead of a poll (#2313).
  defp subscribe_to_resources(state) do
    state.resource_subscription.(self())
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Subscribes the projection to delivery-mode transitions so a repo degrading
  # triggers the rare reconciliation even when nothing else wakes the
  # projection (#2313).
  defp subscribe_to_mode_events(state) do
    state.mode_events_subscriber.()
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end

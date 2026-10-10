defmodule Aiur.BuildOrder.GraphProjection.Authority do
  @moduledoc false

  # Adopting a configuration snapshot, configuration health and root authorization.
  # Runs inside the projection process: every `self()` here is the GenServer.

  alias Aiur.BuildOrder.GitHubGraph.Settings
  alias Aiur.BuildOrder.GraphProjection.{Configuration, Demand, Failure, Policy, Publication, Reads, Resources, Schedule}
  alias Aiur.BuildOrder.ProviderHealth

  @spec reconcile(map(), term()) :: {map(), [tuple()]}
  def reconcile(state, notified_generation \\ nil) do
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
      |> Demand.enforce_retention_bound()
      |> Schedule.reschedule_active_scopes()

    {state, []}
  end

  defp reconcile_snapshot(state, snapshot) do
    old_catalog = Publication.catalog_snapshot(state)

    state =
      state
      |> Reads.cancel_all_tasks()
      |> Schedule.cancel_all_timers()
      |> Resources.cancel_member_due()
      |> Demand.clear_demand_monitors()

    now_ms = Schedule.now_ms(state)

    state = %{
      state
      | catalog: Policy.unavailable_entry(:catalog, now_ms),
        catalog_change_seq: 0,
        # A new authority discards the catalog entirely, so the counts it
        # carried are gone too. Clearing the stamp makes the first read under
        # the new authority a labelled one.
        catalog_labels_read_ms: nil,
        catalog_labels_ok_ms: nil,
        catalog_labels_failure: nil,
        catalog_labels_failure_reset_at: nil,
        catalog_labels_failures: 0,
        catalog_labels_penalty_ms: 0,
        selected: %{},
        # Cleared with the roots they describe. A marker that outlived its graph
        # would tell the next read of that root it was already current when
        # nothing is held for it — and across repeated authority changes the map
        # would grow without bound.
        selected_fingerprints: %{},
        pending: MapSet.new(),
        forced: MapSet.new(),
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
        else: [{:health, Publication.catalog_snapshot(state)}, {:reset, state.authority_epoch}]

    {state, events}
  end

  defp configuration_failed(state) do
    {catalog, catalog_changed?} = fail_configuration(state.catalog, state)

    {selected, selected_events} =
      Enum.reduce(state.selected, {%{}, []}, fn {key, entry}, {entries, events} ->
        {entry, changed?} = fail_configuration(entry, state)
        snapshot = Publication.snapshot_for_entry(entry, state)
        {Map.put(entries, key, entry), if(changed?, do: [{:health, snapshot} | events], else: events)}
      end)

    state =
      state
      |> Reads.cancel_all_tasks()
      |> Schedule.cancel_all_timers()
      |> Map.put(:catalog, catalog)
      |> Map.put(:selected, selected)
      |> Map.put(:pending, MapSet.new())
      |> Map.put(:forced, MapSet.new())

    catalog_events = if(catalog_changed?, do: [{:health, Publication.catalog_snapshot(state)}], else: [])
    {state, catalog_events ++ Enum.reverse(selected_events)}
  end

  defp fail_configuration(%{health: %{failure: :configuration}} = entry, _state), do: {entry, false}

  defp fail_configuration(entry, state) do
    entry = Policy.apply_failure(entry, :configuration, Schedule.now(state), nil, false)
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

  @spec authorize_root(map(), term()) :: {:ok, Aiur.TrackerIdentity.t()} | {:error, Failure.t()}
  def authorize_root(%{catalog: %{health: %{failure: :configuration}}}, _identity),
    do: {:error, %Failure{kind: :configuration}}

  def authorize_root(%{active_repository: {_, _} = repository}, identity) do
    case Settings.requested_root(identity, repository) do
      {:ok, identity} -> {:ok, identity}
      {:error, _reason} -> {:error, %Failure{kind: :invalid_root}}
    end
  end

  def authorize_root(_state, _identity), do: {:error, %Failure{kind: :configuration}}

  defp new_authority_epoch, do: System.unique_integer([:positive, :monotonic])
end

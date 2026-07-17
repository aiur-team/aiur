defmodule Aiur.CurrentRunProjections do
  @moduledoc """
  Owns the two current-run read models behind one supervised runtime child.

  Source events are coalesced before a refresh and periodic ticks bound clock
  and reconciliation drift. Reader failures degrade the public health and
  freshness fields without terminating the owner. Last-known-good snapshots
  are exposed only when the run, denominator or membership, and repository
  fences still match the current projection.
  """

  use GenServer

  alias Aiur.{
    CurrentRunMembership,
    CurrentRunOutcomeSnapshot,
    CurrentRunSummary,
    TrackerIdentity
  }

  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Orchestrator.StatusReport
  alias AiurWeb.OperatorControlCenter.UnitsRow

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
    state = %{
      readers: readers(opts),
      units_snapshot_fun: Keyword.get(opts, :units_snapshot_fun, &UnitsRow.snapshot/1),
      pubsub: Keyword.get(opts, :pubsub, Aiur.PubSub),
      clock_interval_ms: interval(opts, :clock_interval_ms, 1_000),
      reconcile_interval_ms: interval(opts, :reconcile_interval_ms, 30_000),
      sources: empty_sources(),
      availability: %{},
      units: empty_units(),
      issue_cache: %{},
      run_id: nil,
      denominator_signature: nil,
      denominator_generation: 0,
      membership_signature: nil,
      summary_generation: 0,
      outcome_generation: 0,
      summary_snapshot: initial_summary(),
      outcome_snapshot: initial_outcomes(),
      summary_lkg: nil,
      outcome_lkg: nil,
      refresh_pending?: false,
      last_race_signature: nil
    }

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

  def handle_call(:refresh, _from, state) do
    state = state |> Map.put(:refresh_pending?, false) |> refresh_sources()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:refresh_sources, %{refresh_pending?: true} = state) do
    {:noreply, state |> Map.put(:refresh_pending?, false) |> refresh_sources()}
  end

  def handle_info(:refresh_sources, state), do: {:noreply, state}

  def handle_info(:clock_tick, state) do
    state = refresh_clock(state)
    schedule(:clock_tick, state.clock_interval_ms)
    {:noreply, state}
  end

  def handle_info(:reconcile_tick, state) do
    state = state |> Map.put(:refresh_pending?, false) |> refresh_sources()
    schedule(:reconcile_tick, state.reconcile_interval_ms)
    {:noreply, state}
  end

  def handle_info({:current_run_membership_changed, _payload}, state),
    do: {:noreply, schedule_refresh(state)}

  def handle_info({:current_run_membership_health_changed, _payload}, state),
    do: {:noreply, schedule_refresh(state)}

  def handle_info({:ticket_activity_changed, _payload}, state),
    do: {:noreply, schedule_refresh(state)}

  def handle_info({:running_changed, _payload}, state),
    do: {:noreply, schedule_refresh(state)}

  def handle_info({:status_changed, _payload}, state),
    do: {:noreply, schedule_refresh(state)}

  def handle_info(:observability_updated, state), do: {:noreply, schedule_refresh(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp readers(opts) do
    %{
      run: Keyword.get(opts, :run_snapshot_fun, &run_snapshot/0),
      membership: Keyword.get(opts, :membership_snapshot_fun, &CurrentRunMembership.snapshot/0),
      status: Keyword.get(opts, :status_snapshot_fun, &StatusReport.snapshot_api/0),
      status_facts: Keyword.get(opts, :status_facts_fun, &StatusReport.status_api/0),
      activity: Keyword.get(opts, :activity_snapshot_fun, &Aiur.TicketActivity.snapshots/0),
      merges: Keyword.get(opts, :recent_merges_snapshot_fun, &Aiur.RecentMergeStore.snapshot/0),
      configured_repository: Keyword.get(opts, :configured_repository_fun, &GitHubConfig.configured_repo/0)
    }
  end

  defp run_snapshot do
    %{
      id: Aiur.Boot.run_id(),
      started_at: Aiur.Boot.started_at(),
      observed_at: DateTime.utc_now(),
      elapsed_ms: Aiur.Boot.elapsed_ms()
    }
  end

  defp subscribe(opts) do
    subscribe_funs =
      Keyword.get(opts, :subscribe_funs, [
        &Aiur.CurrentRunMembership.subscribe/0,
        &Aiur.TicketActivity.subscribe/0,
        &Aiur.AgentPubSub.subscribe_running/0,
        &Aiur.AgentPubSub.subscribe_status/0,
        &AiurWeb.ObservabilityPubSub.subscribe/0
      ])

    Enum.each(subscribe_funs, &safe_subscribe/1)
  end

  defp safe_subscribe(fun) do
    fun.()
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp interval(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> :infinity
    end
  end

  defp schedule(_message, :infinity), do: :ok
  defp schedule(message, interval), do: Process.send_after(self(), message, interval)

  defp schedule_refresh(%{refresh_pending?: true} = state), do: state

  defp schedule_refresh(state) do
    send(self(), :refresh_sources)
    %{state | refresh_pending?: true}
  end

  defp refresh_sources(state) do
    {sources, availability} = read_sources(state)

    {units, issue_cache, weight_health, race_signature} =
      build_units(state, sources, availability)

    state = %{
      state
      | sources: sources,
        availability: availability,
        units: units,
        issue_cache: issue_cache
    }

    state
    |> project(sources, units, weight_health)
    |> maybe_retry_race(race_signature)
  end

  defp refresh_clock(state) do
    {run, available?} = read_run(state)
    sources = put_in(state.sources, [:run], run)
    availability = Map.put(state.availability, :run, available?)

    state
    |> Map.merge(%{sources: sources, availability: availability})
    |> project(sources, state.units, current_weight_health(state.summary_snapshot))
  end

  defp current_weight_health(%{sources: %{weight_health: health}}), do: health
  defp current_weight_health(_snapshot), do: :unavailable

  defp read_sources(state) do
    {run, run_available?} = read_run(state)
    {membership, membership_available?} = read_membership(state)
    {status, status_available?} = read_status(state)
    {status_facts, status_facts_available?} = read_status_facts(state)
    {activity, activity_available?} = read_activity(state)
    {merges, merges_available?} = read_merges(state)
    {configured_repository, repository_available?} = read_repository(state)

    sources = %{
      run: run,
      membership: membership,
      status: status,
      status_facts: status_facts,
      activity: activity,
      merges: merges,
      configured_repository: configured_repository
    }

    availability = %{
      run: run_available?,
      membership: membership_available?,
      status: status_available?,
      status_facts: status_facts_available?,
      activity: activity_available?,
      merges: merges_available?,
      configured_repository: repository_available?
    }

    {sources, availability}
  end

  defp read_run(state) do
    case safe_read(state.readers.run) do
      {:ok, run} when is_map(run) -> {run, true}
      _result -> {Map.put(state.sources.run, :valid?, false), false}
    end
  end

  defp read_membership(state) do
    case safe_read(state.readers.membership) do
      {:ok, membership} when is_map(membership) -> {membership, true}
      _result -> {stale_membership(state.sources.membership), false}
    end
  end

  defp read_status(state) do
    case safe_read(state.readers.status) do
      {:ok, status} when is_map(status) ->
        {Map.put(status, :health, :available), true}

      _result ->
        status =
          state.sources.status
          |> ensure_status_buckets()
          |> Map.put(:health, :unavailable)
          |> Map.put(:freshness, :stale)

        {status, false}
    end
  end

  defp read_status_facts(state) do
    case safe_read(state.readers.status_facts) do
      {:ok, facts} when is_list(facts) -> {facts, true}
      _result -> {state.sources.status_facts, false}
    end
  end

  defp read_activity(state) do
    case safe_read(state.readers.activity) do
      {:ok, activity} when is_map(activity) ->
        normalized = normalize_activity(activity, :available)
        {normalized, normalized.health == :available}

      _result ->
        {normalize_activity(state.sources.activity, :unavailable), false}
    end
  end

  defp read_merges(state) do
    case safe_read(state.readers.merges) do
      {:ok, merges} when is_map(merges) ->
        {merges, true}

      _result ->
        {Map.put(state.sources.merges, :health, {:unavailable, :read_failed}), false}
    end
  end

  defp read_repository(state) do
    case safe_read(state.readers.configured_repository) do
      {:ok, {:ok, {_owner, _repository}} = repository} -> {repository, true}
      {:ok, {:error, _reason} = error} -> {error, false}
      _result -> {{:error, :configured_repository_unavailable}, false}
    end
  end

  defp safe_read(fun) do
    case fun.() do
      :timeout -> {:error, :timeout}
      :unavailable -> {:error, :unavailable}
      value -> {:ok, value}
    end
  rescue
    _error -> {:error, :exception}
  catch
    _kind, _reason -> {:error, :exit}
  end

  defp stale_membership(membership) do
    membership
    |> Map.put(:health, {:unavailable, :read_failed})
    |> Map.put(:freshness, %{status: :stale})
    |> Map.put_new(:members, [])
  end

  defp ensure_status_buckets(status) do
    status
    |> Map.put_new(:running, [])
    |> Map.put_new(:retrying, [])
    |> Map.put_new(:idle, [])
  end

  defp normalize_activity(activity, health) do
    raw_entries = activity |> Map.get(:entries, []) |> List.wrap()
    entries = Enum.filter(raw_entries, &is_map/1)
    invalid? = length(entries) != length(raw_entries)
    entries = Enum.map(entries, &normalize_activity_entry(&1, health))

    effective_health =
      if health == :available and invalid?, do: :degraded, else: health

    freshness =
      cond do
        health == :unavailable -> :stale
        invalid? -> :partial
        Enum.any?(entries, &stale_activity?/1) -> :stale
        true -> :fresh
      end

    activity
    |> Map.put(:entries, entries)
    |> Map.put(:health, effective_health)
    |> Map.put(:freshness, freshness)
  end

  defp normalize_activity_entry(entry, :unavailable) when is_map(entry) do
    Map.update(entry, :progress, %{status: :unknown}, &stale_progress/1)
  end

  defp normalize_activity_entry(entry, _health), do: entry

  defp stale_progress(progress) when is_map(progress), do: Map.put(progress, :freshness, :stale)
  defp stale_progress(_progress), do: %{status: :unknown}

  defp stale_activity?(%{progress: %{freshness: :stale}}), do: true
  defp stale_activity?(_entry), do: false

  defp build_units(state, sources, availability) do
    members = sources.membership |> Map.get(:members, []) |> List.wrap()
    run_id = Map.get(sources.run, :id)
    cache = cache_for_run(state, run_id)
    facts = Enum.map(sources.status_facts, &normalize_status_fact/1)
    fact_index = identity_index(facts)
    cache = retain_member_cache(cache, members)
    {issue_entries, cache, stale_cache?} = collect_issue_entries(members, fact_index, cache)
    race_signature = status_race_signature(members, sources.status, facts, availability)
    race? = not is_nil(race_signature)
    weight_health = weight_health(availability, stale_cache?, race?)

    unit_inputs = %{
      membership: sources.membership,
      status: sources.status,
      activity: sources.activity,
      decisions: %{entries: [], health: :available, freshness: :fresh},
      issue_facts: %{
        entries: Enum.reverse(issue_entries),
        generation: nil,
        health: issue_source_health(weight_health),
        freshness: issue_source_freshness(weight_health)
      }
    }

    units = units_snapshot(state.units_snapshot_fun, unit_inputs, sources.membership)
    {units, cache, weight_health, race_signature}
  end

  defp cache_for_run(%{run_id: run_id, issue_cache: cache}, run_id), do: cache
  defp cache_for_run(_state, _run_id), do: %{}

  defp retain_member_cache(cache, members) do
    member_keys = members |> Enum.map(&member_key/1) |> Enum.reject(&is_nil/1)
    Map.take(cache, member_keys)
  end

  defp collect_issue_entries(members, fact_index, cache) do
    Enum.reduce(members, {[], cache, false}, fn member, accumulator ->
      collect_issue_entry(member, accumulator, fact_index)
    end)
  end

  defp collect_issue_entry(member, {entries, cache, stale?}, fact_index) do
    key = member_key(member)

    case Map.fetch(fact_index, key) do
      {:ok, fact} -> collect_current_issue_fact(fact, key, entries, cache, stale?)
      :error -> collect_cached_issue_fact(Map.get(cache, key), entries, cache, stale?)
    end
  end

  defp collect_current_issue_fact(fact, key, entries, cache, stale?) do
    if valid_complexity?(Map.get(fact, :complexity)) do
      {[fact | entries], Map.put(cache, key, %{fact: fact}), stale?}
    else
      {[fact | entries], Map.delete(cache, key), stale?}
    end
  end

  defp collect_cached_issue_fact(nil, entries, cache, stale?),
    do: {entries, cache, stale?}

  defp collect_cached_issue_fact(cached, entries, cache, _stale?),
    do: {[cached.fact | entries], cache, true}

  defp weight_health(%{status: false}, _stale_cache?, _race?), do: :unavailable
  defp weight_health(%{status_facts: false}, _stale_cache?, _race?), do: :unavailable
  defp weight_health(_availability, true, _race?), do: :stale
  defp weight_health(_availability, _stale_cache?, true), do: :stale
  defp weight_health(_availability, _stale_cache?, _race?), do: :healthy

  defp issue_source_health(:healthy), do: :available
  defp issue_source_health(_weight_health), do: :degraded

  defp issue_source_freshness(:healthy), do: :fresh
  defp issue_source_freshness(_weight_health), do: :stale

  defp units_snapshot(fun, inputs, membership) do
    case safe_units_snapshot(fun, inputs) do
      {:ok, snapshot} -> snapshot
      :error -> empty_units(membership)
    end
  end

  defp safe_units_snapshot(fun, inputs) do
    case fun.(inputs) do
      snapshot when is_map(snapshot) -> {:ok, snapshot}
      _snapshot -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp normalize_status_fact(fact) when is_map(fact) do
    fact
    |> Map.put(:identity, Map.get(fact, :identity) || Map.get(fact, :tracker_identity))
    |> Map.put(:state, Map.get(fact, :tracker_state) || Map.get(fact, :state))
  end

  defp normalize_status_fact(_fact), do: %{}

  defp valid_complexity?(value), do: is_integer(value) and value in 1..5

  defp identity_index(entries) do
    Enum.reduce(entries, %{}, fn entry, index ->
      case member_key(entry) do
        nil -> index
        key -> Map.put(index, key, entry)
      end
    end)
  end

  defp member_key(%{identity: identity}), do: TrackerIdentity.github_key(identity)
  defp member_key(%{tracker_identity: identity}), do: TrackerIdentity.github_key(identity)
  defp member_key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)
  defp member_key(_member), do: nil

  defp status_race_signature(_members, _status, _facts, %{status: false}), do: nil

  defp status_race_signature(_members, _status, _facts, %{status_facts: false}),
    do: nil

  defp status_race_signature(members, status, facts, _availability) do
    active_keys =
      members
      |> Enum.reject(&(Map.get(&1, :terminal?) == true))
      |> Enum.map(&member_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    status_keys =
      [:running, :retrying, :idle]
      |> Enum.flat_map(&List.wrap(Map.get(status, &1, [])))
      |> Enum.map(&member_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
      |> MapSet.intersection(active_keys)

    fact_keys =
      facts
      |> Enum.map(&member_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
      |> MapSet.intersection(active_keys)

    mismatch = MapSet.symmetric_difference(status_keys, fact_keys)

    if MapSet.size(mismatch) == 0 do
      nil
    else
      mismatch |> MapSet.to_list() |> Enum.sort() |> :erlang.phash2()
    end
  end

  defp maybe_retry_race(state, nil), do: %{state | last_race_signature: nil}

  defp maybe_retry_race(state, signature) do
    if state.last_race_signature == signature do
      state
    else
      state |> Map.put(:last_race_signature, signature) |> schedule_refresh()
    end
  end

  defp project(state, sources, units, weight_health) do
    run_id = Map.get(sources.run, :id)

    denominator_signature =
      CurrentRunSummary.Projection.denominator_signature(Map.get(units, :rows, []))

    denominator_generation =
      next_denominator_generation(
        state.run_id,
        run_id,
        state.denominator_signature,
        denominator_signature,
        state.denominator_generation
      )

    membership_signature =
      CurrentRunOutcomeSnapshot.Projection.membership_signature(Map.get(sources.membership, :members, []))

    summary_raw =
      CurrentRunSummary.Projection.snapshot(%{
        run: sources.run,
        units: units,
        generation: 0,
        denominator_generation: denominator_generation,
        weight_health: weight_health
      })

    outcome_raw =
      CurrentRunOutcomeSnapshot.Projection.snapshot(%{
        run: summary_raw.run,
        membership: sources.membership,
        recent_merges: sources.merges,
        configured_repository: sources.configured_repository,
        generation: 0
      })

    {summary_snapshot, summary_generation, summary_lkg, summary_changed?} =
      finalize_summary(state, summary_raw, run_id, denominator_signature)

    {outcome_snapshot, outcome_generation, outcome_lkg, outcome_changed?} =
      finalize_outcomes(state, outcome_raw, run_id, membership_signature)

    if summary_changed? do
      broadcast(
        state.pubsub,
        CurrentRunSummary.topic(),
        {:current_run_summary_changed, summary_snapshot}
      )
    end

    if outcome_changed? do
      broadcast(
        state.pubsub,
        CurrentRunOutcomeSnapshot.topic(),
        {:current_run_outcome_snapshot_changed, outcome_snapshot}
      )
    end

    %{
      state
      | run_id: run_id,
        denominator_signature: denominator_signature,
        denominator_generation: denominator_generation,
        membership_signature: membership_signature,
        summary_generation: summary_generation,
        outcome_generation: outcome_generation,
        summary_snapshot: summary_snapshot,
        outcome_snapshot: outcome_snapshot,
        summary_lkg: summary_lkg,
        outcome_lkg: outcome_lkg
    }
  end

  defp next_denominator_generation(previous_run, run, _previous, _current, _generation)
       when previous_run != run,
       do: 1

  defp next_denominator_generation(run, run, nil, _signature, _generation), do: 1

  defp next_denominator_generation(run, run, signature, signature, generation),
    do: generation

  defp next_denominator_generation(run, run, _previous, _current, generation),
    do: generation + 1

  defp finalize_summary(state, raw, run_id, denominator_signature) do
    changed? = summary_semantic(state.summary_snapshot) != summary_semantic(raw)
    generation = if changed?, do: state.summary_generation + 1, else: state.summary_generation
    current = raw |> Map.put(:generation, generation) |> Map.put(:last_known_good, nil)
    key = {run_id, denominator_signature}
    previous_lkg = same_lkg(state.summary_lkg, key)

    {current, lkg} =
      if good_summary?(current) do
        {current, new_lkg(key, current)}
      else
        {Map.put(current, :last_known_good, public_lkg(previous_lkg)), previous_lkg}
      end

    {current, generation, lkg, changed?}
  end

  defp finalize_outcomes(state, raw, run_id, membership_signature) do
    changed? = outcome_semantic(state.outcome_snapshot) != outcome_semantic(raw)
    generation = if changed?, do: state.outcome_generation + 1, else: state.outcome_generation
    current = raw |> Map.put(:generation, generation) |> Map.put(:last_known_good, nil)
    key = {run_id, membership_signature, raw.repository}
    previous_lkg = same_lkg(state.outcome_lkg, key)

    {current, lkg} =
      if good_outcomes?(current) do
        {current, new_lkg(key, current)}
      else
        {Map.put(current, :last_known_good, public_lkg(previous_lkg)), previous_lkg}
      end

    {current, generation, lkg, changed?}
  end

  defp summary_semantic(snapshot) when is_map(snapshot),
    do: Map.drop(snapshot, [:generation, :last_known_good])

  defp summary_semantic(_snapshot), do: nil

  defp outcome_semantic(snapshot) when is_map(snapshot) do
    snapshot
    |> Map.drop([:generation, :last_known_good])
    |> Map.update(:run, %{}, &Map.delete(&1, :observed_at))
    |> Map.update(:outcomes, [], fn outcomes ->
      Enum.map(outcomes, fn outcome ->
        Map.update(outcome, :run, %{}, &Map.delete(&1, :observed_at))
      end)
    end)
  end

  defp outcome_semantic(_snapshot), do: nil

  defp good_summary?(snapshot) do
    snapshot.health.status == :healthy and snapshot.freshness.status == :fresh and
      not is_nil(snapshot.progress.exact)
  end

  defp good_outcomes?(snapshot) do
    snapshot.state in [:healthy, :healthy_empty] and snapshot.completeness == :complete and
      snapshot.truncated? == false
  end

  defp new_lkg(key, snapshot) do
    %{
      key: key,
      snapshot: Map.put(snapshot, :last_known_good, nil),
      observed_at: get_in(snapshot, [:run, :observed_at])
    }
  end

  defp same_lkg(%{key: key} = lkg, key), do: lkg
  defp same_lkg(_lkg, _key), do: nil

  defp public_lkg(nil), do: nil

  defp public_lkg(lkg) do
    %{observed_at: lkg.observed_at, generation: lkg.snapshot.generation, snapshot: lkg.snapshot}
  end

  defp broadcast(pubsub, topic, message) do
    if is_pid(Process.whereis(pubsub)), do: Phoenix.PubSub.broadcast(pubsub, topic, message)
    :ok
  end

  defp empty_sources do
    %{
      run: %{},
      membership: %{
        run_id: nil,
        generation: 0,
        health: {:unavailable, :not_read},
        freshness: %{status: :stale},
        truncated?: false,
        members: []
      },
      status: %{running: [], retrying: [], idle: [], health: :unavailable},
      status_facts: [],
      activity: %{generation: 0, entries: [], health: :unavailable, freshness: :stale},
      merges: %{
        merges: [],
        health: {:unavailable, :not_read},
        reconciliation: %{status: :unknown, partial?: nil, pages_fetched: 0}
      },
      configured_repository: {:error, :configured_repository_unavailable}
    }
  end

  defp empty_units(membership \\ nil) do
    membership = membership || empty_sources().membership

    %{
      version: UnitsRow.version(),
      generation: %{membership: Map.get(membership, :generation)},
      health: %{
        membership: :unavailable,
        status: :unavailable,
        activity: :unavailable,
        issue: :unavailable
      },
      freshness: %{
        membership: :stale,
        status: :stale,
        activity: :stale,
        issue: :stale
      },
      truncated?: Map.get(membership, :truncated?, false),
      rows: []
    }
  end

  defp initial_summary do
    CurrentRunSummary.Projection.snapshot(%{
      run: %{},
      units: empty_units(),
      generation: 0,
      denominator_generation: 0,
      weight_health: :unavailable
    })
    |> Map.put(:last_known_good, nil)
  end

  defp initial_outcomes do
    CurrentRunOutcomeSnapshot.Projection.snapshot(%{
      run: %{},
      membership: empty_sources().membership,
      recent_merges: empty_sources().merges,
      configured_repository: {:error, :configured_repository_unavailable},
      generation: 0
    })
    |> Map.put(:last_known_good, nil)
  end
end

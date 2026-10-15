defmodule Aiur.CurrentRunProjections.ReadApiTest do
  use ExUnit.Case, async: true

  import Aiur.CurrentRunProjectionsSupport

  alias Aiur.CurrentRunOutcomeSnapshot
  alias Aiur.CurrentRunProjections
  alias Aiur.CurrentRunProjections.SourceAdapter
  alias Aiur.CurrentRunProjections.State
  alias Aiur.CurrentRunSummary
  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.ObservabilityPubSub
  alias AiurWeb.OperatorControlCenter.RunSummaryPresenter

  test "refreshes both projections, publishes changes, and serves read APIs" do
    {source, owner, pubsub} = start_owner()

    assert :ok = CurrentRunSummary.subscribe(pubsub: pubsub)
    assert :ok = CurrentRunOutcomeSnapshot.subscribe(pubsub: pubsub)
    assert :ok = CurrentRunProjections.refresh(owner)

    assert_receive {:current_run_summary_changed, summary}, 1000
    assert_receive {:current_run_outcome_snapshot_changed, outcomes}, 1000

    assert summary.health.status == :healthy
    assert summary.freshness.status == :fresh
    assert summary.progress.exact == %{numerator: 2, denominator: 5}
    assert outcomes.state == :healthy
    assert outcomes.completeness == :complete
    assert length(outcomes.outcomes) == 1

    # The bounded source adapter must retain the existing routing facts that
    # the Units row already knows how to render as agent/model tags.
    assert [unit] = :sys.get_state(owner).units.rows
    assert unit.backend == :codex
    assert unit.agent_family == :codex
    assert unit.requested_model == "gpt-5"

    assert CurrentRunSummary.snapshot(server: owner) == summary
    assert CurrentRunSummary.health(server: owner) == summary.health
    assert CurrentRunSummary.freshness(server: owner) == summary.freshness
    assert CurrentRunSummary.generation(server: owner) == summary.generation

    assert CurrentRunOutcomeSnapshot.snapshot(server: owner) == outcomes
    assert CurrentRunOutcomeSnapshot.health(server: owner) == outcomes.health
    assert CurrentRunOutcomeSnapshot.generation(server: owner) == outcomes.generation
    assert Process.alive?(source)
  end

  test "observability broadcasts schedule a projection refresh" do
    test_pid = self()
    {source, _owner, pubsub} = start_owner(fn value -> Map.put(value, :run, {:block, test_pid}) end, observability_subscription?: true)

    assert :ok = ObservabilityPubSub.broadcast_update(pubsub)
    assert_receive {:projection_reader_blocked, :run, _reader}, 1_000
    assert Agent.get(source, & &1.run_reads) == 1
  end

  test "default status readers consume only a current cached fleet snapshot" do
    test_pid = self()
    snapshot = Map.merge(sources().status, %{statuses: sources().status_facts})

    cache_reader = fn server, timeout, opts ->
      send(test_pid, {:snapshot_store_read, server, timeout, opts})
      {:current, snapshot, %{status: :current}}
    end

    state = State.new(name: nil, snapshot_store_read_fun: cache_reader)

    assert state.readers.status.() == snapshot
    assert state.readers.status_facts.() == snapshot.statuses

    assert_receive {:snapshot_store_read, Aiur.Orchestrator, 5_000, []}, 1000
    assert_receive {:snapshot_store_read, Aiur.Orchestrator, 5_000, [fleet_rows?: true]}, 1000
    refute_receive _message, 100
  end

  test "default status readers reject stale and missing cached fleet snapshots" do
    snapshot = Map.merge(sources().status, %{statuses: sources().status_facts})

    for result <- [
          {:stale, snapshot, %{status: :stale}},
          :snapshot_unpublished,
          :orchestrator_unavailable
        ] do
      state = State.new(name: nil, snapshot_store_read_fun: fn _, _, _ -> result end)

      assert state.readers.status.() == :unavailable
      assert state.readers.status_facts.() == :unavailable
    end
  end

  test "a cold cache never calls the Orchestrator status path" do
    test_pid = self()
    orchestrator = unique_name(:cold_cache_orchestrator)
    probe = spawn(fn -> report_messages(test_pid) end)
    true = Process.register(probe, orchestrator)

    on_exit(fn ->
      SnapshotStore.forget(orchestrator)
      if Process.alive?(probe), do: Process.exit(probe, :kill)
    end)

    state = State.new(name: nil, status_orchestrator: orchestrator)

    assert state.readers.status.() == :unavailable
    assert state.readers.status_facts.() == :unavailable
    refute_receive {:orchestrator_message, _message}, 100
  end

  test "cached status readers preserve routing facts through the Units projection" do
    source =
      start_supervised!(Supervisor.child_spec({Agent, fn -> sources() end}, id: unique_name(:cached_reader_source)))

    cache =
      start_supervised!(Supervisor.child_spec({Agent, fn -> :current end}, id: unique_name(:cached_reader_cache)))

    pubsub = unique_name(:cached_reader_pubsub)
    start_supervised!({Phoenix.PubSub, name: pubsub})

    cache_reader = fn _server, _timeout, _opts ->
      status = Agent.get(source, & &1.status)
      status_facts = Agent.get(source, & &1.status_facts)

      case Agent.get(cache, & &1) do
        :current -> {:current, Map.put(status, :statuses, status_facts), %{status: :current}}
        :stale -> {:stale, Map.put(status, :statuses, status_facts), %{status: :stale}}
      end
    end

    opts =
      source
      |> owner_options(pubsub, snapshot_store_read_fun: cache_reader)
      |> Keyword.delete(:status_snapshot_fun)
      |> Keyword.delete(:status_facts_fun)

    owner = start_supervised!({CurrentRunProjections, opts})

    assert :ok = CurrentRunProjections.refresh(owner)
    assert %{status: true, status_facts: true} = :sys.get_state(owner).availability

    assert [unit] = :sys.get_state(owner).units.rows
    assert unit.backend == :codex
    assert unit.agent_family == :codex
    assert unit.requested_model == "gpt-5"

    Agent.update(cache, fn _ -> :stale end)
    assert :ok = CurrentRunProjections.refresh(owner)

    degraded = :sys.get_state(owner)
    assert %{status: false, status_facts: false} = degraded.availability
    assert degraded.sources.status.health == :unavailable
    assert degraded.sources.status.freshness == :stale
    assert [retained_unit] = degraded.units.rows
    assert retained_unit.agent_family == :codex
  end

  test "status sanitization retains existing routing facts in map and list forms" do
    ticket = identity()

    routing = %{
      backend: :codex,
      selected_backend: :claude,
      agent_family: :codex,
      requested_model: "gpt-5",
      resolved_model: "gpt-5.6"
    }

    assert {:ok, %{running: [status_row]}} =
             SourceAdapter.read(:status, fn ->
               %{running: [Map.merge(%{tracker_identity: ticket}, routing)], retrying: [], idle: []}
             end)

    assert Map.take(status_row, Map.keys(routing)) == routing

    assert {:ok, [status_fact]} =
             SourceAdapter.read(:status_facts, fn ->
               [Map.merge(%{tracker_identity: ticket, complexity: 3}, routing)]
             end)

    assert Map.take(status_fact, Map.keys(routing)) == routing
  end

  test "a post-bootstrap run read failure exposes same-fence last-known-good snapshots" do
    {source, owner, _pubsub} = start_owner()
    :ok = CurrentRunProjections.refresh(owner)

    good_summary = CurrentRunSummary.snapshot(server: owner)
    good_outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert good_summary.health.status == :healthy
    assert good_outcomes.state == :healthy

    Agent.update(source, &Map.put(&1, :run, :timeout))
    assert :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)
    outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)

    assert summary.health.status == :unavailable
    assert :invalid_run_window in summary.health.reasons
    assert summary.last_known_good.generation == good_summary.generation
    assert summary.last_known_good.snapshot.health.status == :healthy

    assert outcomes.state == :unavailable
    assert outcomes.last_known_good.generation == good_outcomes.generation
    assert outcomes.last_known_good.snapshot.state == :healthy
    assert Process.alive?(owner)
  end

  # Live-run regression: a superseded (replaced) member never gets another
  # status fact, and its permanently missing fact must not mark the whole
  # run's weight facts stale — that degraded health/ETA to "unhealthy weight
  # facts" on the dashboard while every live ticket's facts were current.
  test "a replaced member without a status fact does not poison weight-fact health" do
    replaced = identity(40)

    {_source, owner, _pubsub} =
      start_owner(fn sources ->
        update_in(sources, [:membership, :members], fn members ->
          members ++ [member(replaced, :replaced, false)]
        end)
      end)

    assert :ok = CurrentRunProjections.refresh(owner)
    summary = CurrentRunSummary.snapshot(server: owner)

    assert summary.health.status == :healthy
    refute :unhealthy_weight_facts in summary.health.reasons
    # The replaced member's own weight is honestly unknown, so coverage is
    # :partial — but never :stale, which would misreport a fault.
    assert summary.freshness.status == :partial
    assert summary.sources.weight_health == :healthy
    assert summary.eta.reason != :unhealthy_weight_facts
  end

  test "missing current weight facts retain a current-facts-only progress figure" do
    pending = identity(33)

    {source, owner, _pubsub} =
      start_owner(fn sources ->
        sources
        |> update_in([:membership, :members], &(&1 ++ [member(pending, :running, false)]))
        |> update_in([:status, :running], &(&1 ++ [status_row(pending)]))
        |> update_in([:activity, :entries], &(&1 ++ [activity_entry(pending, 80)]))
      end)

    assert :ok = CurrentRunProjections.refresh(owner)
    summary = CurrentRunSummary.snapshot(server: owner)

    assert summary.health.status == :partial
    assert summary.progress.exact == nil
    assert summary.progress.current_facts.status == :settling
    assert summary.progress.current_facts.value == %{numerator: 2, denominator: 5}
    assert summary.progress.current_facts.current_member_count == 1
    assert summary.progress.current_facts.total_member_count == 2
    assert summary.progress.current_facts.missing_member_count == 1

    view = RunSummaryPresenter.present(summary)
    assert view.progress.kind == :partial
    assert view.progress.percent == 40
    assert view.eta.label == "ETA pending — progress inputs are still settling"
    refute view.eta.label =~ "weight facts"

    await_projection_idle(owner)
    Agent.update(source, &Map.put(&1, :status, :timeout))
    assert :ok = CurrentRunProjections.refresh(owner)

    degraded = CurrentRunSummary.snapshot(server: owner)
    assert :sys.get_state(owner).weight_health == :unavailable
    assert degraded.progress.current_facts.status == :degraded
    assert degraded.progress.current_facts.value == %{numerator: 2, denominator: 5}

    degraded_view = RunSummaryPresenter.present(degraded)
    assert degraded_view.progress.fact_status_label == "Not updating"
    assert degraded_view.eta.label == "ETA unavailable — progress is not updating"
    refute degraded_view.eta.label =~ "weight facts"
  end

  test "retained facts for active members are excluded from current-facts progress" do
    {source, owner, _pubsub} = start_owner()

    assert :ok = CurrentRunProjections.refresh(owner)
    assert CurrentRunSummary.snapshot(server: owner).progress.current_facts.current_member_count == 1

    Agent.update(source, &Map.put(&1, :status_facts, []))
    assert :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)

    assert summary.progress.exact == nil
    assert summary.progress.current_facts.status == :settling
    assert summary.progress.current_facts.value == nil
    assert summary.progress.current_facts.current_member_count == 0
    assert summary.progress.current_facts.total_member_count == 1
    assert summary.progress.current_facts.missing_member_count == 1

    settling_view = RunSummaryPresenter.present(summary)
    assert settling_view.progress.kind == :pending
    assert settling_view.progress.progress_status_label == "Progress not computed yet"
    assert settling_view.progress.fact_status_label == "Still settling"

    await_projection_idle(owner)
    Agent.update(source, &Map.put(&1, :status, :timeout))
    assert :ok = CurrentRunProjections.refresh(owner)

    degraded_view =
      owner
      |> then(&CurrentRunSummary.snapshot(server: &1))
      |> RunSummaryPresenter.present()

    assert degraded_view.progress.kind == :pending
    assert degraded_view.progress.progress_status_label == "Progress unavailable"
    assert degraded_view.progress.fact_status_label == "Not updating"
  end

  test "terminal retained facts remain current progress inputs" do
    {source, owner, _pubsub} = start_owner(fn _sources -> weighted_sources() end)

    assert :ok = CurrentRunProjections.refresh(owner)
    assert CurrentRunSummary.snapshot(server: owner).progress.current_facts.current_member_count == 3

    Agent.update(source, fn sources ->
      Map.put(sources, :status_facts, [List.last(sources.status_facts)])
    end)

    assert :ok = CurrentRunProjections.refresh(owner)
    summary = CurrentRunSummary.snapshot(server: owner)

    assert summary.health.status == :healthy
    assert summary.progress.exact == %{numerator: 3, denominator: 5}
    assert summary.progress.current_facts.value == %{numerator: 3, denominator: 5}
    assert summary.progress.current_facts.current_member_count == 3
    assert summary.progress.current_facts.missing_member_count == 0
  end

  test "malformed activity degrades and a later timeout cannot crash the owner" do
    {source, owner, _pubsub} = start_owner()
    :ok = CurrentRunProjections.refresh(owner)

    valid_entry = activity_entry(identity(), 55)

    Agent.update(source, fn sources ->
      Map.put(sources, :activity, %{generation: 2, entries: [:malformed, valid_entry]})
    end)

    assert :ok = CurrentRunProjections.refresh(owner)
    summary = CurrentRunSummary.snapshot(server: owner)
    assert summary.health.status == :partial
    assert :unhealthy_activity in summary.health.reasons
    assert summary.sources.activity_health == :degraded
    assert Process.alive?(owner)

    Agent.update(source, &Map.put(&1, :activity, :timeout))
    assert :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)
    assert summary.health.status == :partial
    assert summary.sources.activity_health == :unavailable
    assert summary.freshness.status == :stale
    assert Process.alive?(owner)
  end

  test "status reader failures mark retained status and issue facts stale" do
    {source, owner, _pubsub} = start_owner()
    :ok = CurrentRunProjections.refresh(owner)
    good = CurrentRunSummary.snapshot(server: owner)

    Agent.update(source, &Map.put(&1, :status, :timeout))
    assert :ok = CurrentRunProjections.refresh(owner)

    status_stale = CurrentRunSummary.snapshot(server: owner)
    assert status_stale.health.status == :partial
    assert status_stale.sources.status_health == :unavailable
    assert status_stale.freshness.status == :stale
    assert status_stale.last_known_good.generation == good.generation

    Agent.update(source, fn current ->
      current
      |> Map.put(:status, sources().status)
      |> Map.put(:status_facts, :timeout)
    end)

    assert :ok = CurrentRunProjections.refresh(owner)

    issue_stale = CurrentRunSummary.snapshot(server: owner)
    assert issue_stale.health.status == :partial
    assert issue_stale.sources.issue_health == :degraded
    assert issue_stale.sources.weight_health == :unavailable
    assert issue_stale.freshness.status == :stale
    assert issue_stale.progress.current_facts.status == :degraded
    assert issue_stale.progress.current_facts.value == nil
    assert issue_stale.progress.current_facts.current_member_count == 0

    issue_view = RunSummaryPresenter.present(issue_stale)
    assert issue_view.progress.kind == :pending
    assert issue_view.progress.progress_status_label == "Progress unavailable"
    assert issue_view.progress.fact_status_label == "Not updating"
    assert issue_stale.last_known_good.generation == good.generation
    assert Process.alive?(owner)
  end
end

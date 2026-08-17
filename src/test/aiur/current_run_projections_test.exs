defmodule Aiur.CurrentRunProjectionsTest do
  use ExUnit.Case, async: true

  alias Aiur.{
    CurrentRunOutcomeSnapshot,
    CurrentRunProjections,
    CurrentRunSummary,
    RecentMerge,
    TrackerIdentity
  }

  alias Aiur.CurrentRunOutcomeSnapshot.MembershipIndex
  alias Aiur.CurrentRunProjections.{Checkpoint, Projector}
  alias AiurWeb.OperatorControlCenter.RunSummaryPresenter

  test "refreshes both projections, publishes changes, and serves read APIs" do
    {source, owner, pubsub} = start_owner()

    assert :ok = CurrentRunSummary.subscribe(pubsub: pubsub)
    assert :ok = CurrentRunOutcomeSnapshot.subscribe(pubsub: pubsub)
    assert :ok = CurrentRunProjections.refresh(owner)

    assert_receive {:current_run_summary_changed, summary}
    assert_receive {:current_run_outcome_snapshot_changed, outcomes}

    assert summary.health.status == :healthy
    assert summary.freshness.status == :fresh
    assert summary.progress.exact == %{numerator: 2, denominator: 5}
    assert outcomes.state == :healthy
    assert outcomes.completeness == :complete
    assert length(outcomes.outcomes) == 1

    assert CurrentRunSummary.snapshot(server: owner) == summary
    assert CurrentRunSummary.health(server: owner) == summary.health
    assert CurrentRunSummary.freshness(server: owner) == summary.freshness
    assert CurrentRunSummary.generation(server: owner) == summary.generation

    assert CurrentRunOutcomeSnapshot.snapshot(server: owner) == outcomes
    assert CurrentRunOutcomeSnapshot.health(server: owner) == outcomes.health
    assert CurrentRunOutcomeSnapshot.generation(server: owner) == outcomes.generation
    assert Process.alive?(source)
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
    assert degraded_view.progress.fact_status_label == "Refresh degraded"
    assert degraded_view.eta.label == "ETA unavailable — progress refresh degraded"
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
    assert degraded_view.progress.fact_status_label == "Refresh degraded"
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
    assert issue_view.progress.fact_status_label == "Refresh degraded"
    assert issue_stale.last_known_good.generation == good.generation
    assert Process.alive?(owner)
  end

  test "membership reconciliation freshness transitions projections from partial to exact" do
    {source, owner, _pubsub} =
      start_owner(fn sources ->
        put_in(sources, [:membership, :freshness], %{status: :unknown})
      end)

    :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)
    outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert summary.health.status == :partial
    assert summary.progress.exact == nil
    assert summary.freshness.status == :unknown
    assert outcomes.state == :partial
    assert outcomes.completeness == :partial

    Agent.update(source, &put_in(&1, [:membership, :freshness], %{status: :fresh}))
    assert :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)
    outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert summary.health.status == :healthy
    assert summary.progress.exact == %{numerator: 2, denominator: 5}
    assert outcomes.state == :healthy
    assert outcomes.completeness == :complete
  end

  test "denominator generation changes only at run or weight boundaries" do
    {source, owner, _pubsub} = start_owner()
    :ok = CurrentRunProjections.refresh(owner)
    first = CurrentRunSummary.snapshot(server: owner)
    assert first.denominator.generation == 1

    Agent.update(source, fn sources ->
      put_in(sources, [:activity, :entries], [activity_entry(identity(), 60)])
    end)

    :ok = CurrentRunProjections.refresh(owner)
    progress_only = CurrentRunSummary.snapshot(server: owner)
    assert progress_only.denominator.generation == 1
    assert progress_only.progress.exact == %{numerator: 3, denominator: 5}

    Agent.update(source, fn sources ->
      put_in(sources, [:status_facts, Access.at(0), :complexity], 4)
    end)

    :ok = CurrentRunProjections.refresh(owner)
    reweighted = CurrentRunSummary.snapshot(server: owner)
    assert reweighted.denominator.generation == 2

    Agent.update(source, fn sources ->
      sources
      |> put_in([:run, :id], "run-2")
      |> put_in([:membership, :run_id], "run-2")
    end)

    :ok = CurrentRunProjections.refresh(owner)
    next_run = CurrentRunSummary.snapshot(server: owner)
    assert next_run.run.id == "run-2"
    assert next_run.denominator.generation == 1
    assert next_run.last_known_good == nil
  end

  test "source event bursts coalesce without making the owner unavailable" do
    test_pid = self()

    {source, owner, _pubsub} =
      start_owner(fn value -> value end,
        checkpoint_writer: fn _run_id, _checkpoint ->
          send(test_pid, :projection_checkpoint_written)
          :ok
        end
      )

    :ok = CurrentRunProjections.refresh(owner)
    assert_receive :projection_checkpoint_written, 2_000
    assert Agent.get(source, & &1.run_reads) == 1

    :ok = :sys.suspend(owner)
    send(owner, {:ticket_activity_changed, %{}})
    send(owner, {:status_changed, %{}})
    send(owner, {:running_changed, %{}})
    :ok = :sys.resume(owner)

    assert_receive :projection_checkpoint_written, 2_000
    refute_receive :projection_checkpoint_written, 50
    assert Agent.get(source, & &1.run_reads) == 2
    assert CurrentRunSummary.health(server: owner).status == :healthy
    assert Process.alive?(owner)
  end

  test "refresh called during an older full refresh waits for a post-call read" do
    {source, owner, _pubsub} = start_owner()
    original_status = Agent.get(source, & &1.status)
    test_pid = self()

    Agent.update(source, &Map.put(&1, :status, {:block, test_pid}))
    first_refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)

    assert_receive {:projection_reader_blocked, :status, status_reader}, 2_000

    # Change the source after the first refresh has already read it. A second
    # synchronous refresh must not join that pre-call read and return stale
    # data; it waits for a follow-up refresh that begins after this call.
    Agent.update(source, &Map.put(&1, :status, :timeout))
    second_refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)

    assert wait_for_refresh_waiters(owner, 2)
    send(status_reader, {:release_projection_reader, :status, original_status})

    assert Task.await(first_refresh, 2_000) == :ok
    assert Task.await(second_refresh, 2_000) == :ok
    assert :sys.get_state(owner).weight_health == :unavailable
  end

  test "blocked source readers run concurrently while snapshots remain readable" do
    {source, owner, _pubsub} = start_owner(fn value -> value end, source_timeout_ms: 2_500)
    :ok = CurrentRunProjections.refresh(owner)
    baseline = CurrentRunSummary.snapshot(server: owner)
    reader_keys = [:run, :membership, :status, :status_facts, :activity, :merges, :configured_repository]
    test_pid = self()

    Agent.update(source, fn current ->
      Enum.reduce(reader_keys, current, &Map.put(&2, &1, {:block, test_pid}))
    end)

    refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)

    blocked_keys =
      Enum.map(reader_keys, fn _key ->
        assert_receive {:projection_reader_blocked, key, _reader}, 2_000
        key
      end)

    assert MapSet.new(blocked_keys) == MapSet.new(reader_keys)

    read = Task.async(fn -> CurrentRunSummary.snapshot(server: owner) end)
    visible = Task.await(read, 2_000)

    assert visible.generation == baseline.generation
    assert visible.freshness.status == :stale
    assert visible.freshness.refreshing?
    assert :source_refresh_in_progress in visible.health.reasons

    assert Task.await(refresh, 4_000) == :ok
    assert CurrentRunSummary.snapshot(server: owner).health.status == :unavailable
    assert Process.alive?(owner)
  end

  test "reader-boundary sanitization keeps raw issue and workspace facts out of owner state" do
    sentinel = "FORBIDDEN-RAW-WORKSPACE-#{System.unique_integer([:positive])}"
    test_pid = self()

    {source, owner, _pubsub} =
      start_owner(
        fn current ->
          current
          |> put_in([:run, :workspace_path], sentinel)
          |> put_in([:membership, :members, Access.at(0), :raw_issue], %{body: sentinel})
          |> put_in([:membership, :members, Access.at(0), :workspace_path], sentinel)
          |> put_in([:status, :running, Access.at(0), :title], sentinel)
          |> put_in([:status_facts, Access.at(0), :body], sentinel)
          |> put_in([:status_facts, Access.at(0), :workspace_path], sentinel)
          |> put_in([:activity, :entries, Access.at(0), :raw_issue], sentinel)
          |> update_in([:merges, :merges, Access.at(0)], &%{&1 | content_hash: sentinel})
        end,
        checkpoint_writer: fn _run_id, checkpoint ->
          send(test_pid, {:sanitized_projection_checkpoint, checkpoint})
          :ok
        end
      )

    assert :ok = CurrentRunProjections.refresh(owner)
    assert_receive {:sanitized_projection_checkpoint, checkpoint}, 2_000
    state_text = inspect(:sys.get_state(owner), limit: :infinity, printable_limit: :infinity)
    checkpoint_text = inspect(checkpoint, limit: :infinity, printable_limit: :infinity)

    refute state_text =~ sentinel
    refute checkpoint_text =~ sentinel
    refute inspect(CurrentRunSummary.snapshot(server: owner), limit: :infinity) =~ sentinel
    refute inspect(CurrentRunOutcomeSnapshot.snapshot(server: owner), limit: :infinity) =~ sentinel
    assert Process.alive?(source)
  end

  test "checkpoint fallback collections remain bounded" do
    oversized = Enum.map(1..1_001, &%{identity: identity(&1)})

    checkpoint =
      Checkpoint.dump(%{
        sources: %{
          membership: %{members: oversized, truncated?: false},
          status: %{running: oversized, retrying: oversized, idle: oversized},
          status_facts: oversized,
          activity: %{entries: oversized},
          merges: %{merges: oversized}
        },
        units: %{rows: oversized},
        weight_facts: Map.new(1..1_001, &{&1, %{complexity: 1}})
      })

    assert length(checkpoint.sources.membership.members) == 1_000
    assert checkpoint.sources.membership.truncated?
    assert length(checkpoint.sources.status.running) == 1_000
    assert length(checkpoint.sources.status_facts) == 1_000
    assert length(checkpoint.sources.activity.entries) == 1_000
    assert length(checkpoint.sources.merges.merges) == 1_000
    assert length(checkpoint.units.rows) == 1_000
    assert map_size(checkpoint.weight_facts) == 1_000
  end

  test "membership generation fences outcome last-known-good snapshots" do
    {source, owner, _pubsub} = start_owner()
    assert :ok = CurrentRunProjections.refresh(owner)
    good = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert good.state == :healthy

    Agent.update(source, fn current ->
      current
      |> put_in([:membership, :generation], current.membership.generation + 1)
      |> Map.put(:merges, :timeout)
    end)

    assert :ok = CurrentRunProjections.refresh(owner)
    degraded = CurrentRunOutcomeSnapshot.snapshot(server: owner)

    assert degraded.membership.signature == good.membership.signature
    assert degraded.membership.generation == good.membership.generation + 1
    assert degraded.state == :unavailable
    assert degraded.last_known_good == nil
  end

  test "merge and configured-repository outages cannot report fresh outcomes" do
    {source, owner, _pubsub} = start_owner()
    baseline = sources()
    assert :ok = CurrentRunProjections.refresh(owner)

    for {key, reason} <- [merges: :merge_source_unavailable, configured_repository: :configured_repository_unavailable] do
      Agent.update(source, &Map.put(&1, key, :timeout))
      assert :ok = CurrentRunProjections.refresh(owner)
      snapshot = CurrentRunOutcomeSnapshot.snapshot(server: owner)

      assert snapshot.state == :unavailable
      assert snapshot.freshness.status == :unavailable
      assert reason in snapshot.health.reasons

      Agent.update(source, &Map.put(&1, key, Map.fetch!(baseline, key)))
      assert :ok = CurrentRunProjections.refresh(owner)
      assert CurrentRunOutcomeSnapshot.snapshot(server: owner).freshness.status == :fresh
    end
  end

  test "missing scalar generations stay nil and membership freshness remains source-specific" do
    {_source, owner, _pubsub} =
      start_owner(fn current ->
        current
        |> update_in([:status], &Map.delete(&1, :generation))
        |> update_in([:merges], fn merges ->
          merges
          |> Map.delete(:generation)
          |> put_in([:reconciliation, :status], :partial)
        end)
      end)

    assert :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)
    outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)

    assert summary.sources.status_generation == nil
    assert outcomes.sources.merge_generation == nil
    assert outcomes.sources.membership_generation == 3
    assert outcomes.sources.membership_freshness == :fresh
    assert outcomes.freshness.status == :partial
    assert outcomes.state == :partial
    assert :reconciliation_incomplete in outcomes.health.reasons
    refute :membership_freshness_partial in outcomes.health.reasons
  end

  test "membership indexes rebuild only when the authoritative generation changes" do
    counter = :counters.new(1, [:atomics])
    test_pid = self()

    membership_index_fun = fn members ->
      :counters.add(counter, 1, 1)
      MembershipIndex.build(members)
    end

    {source, owner, _pubsub} =
      start_owner(fn value -> value end,
        membership_index_fun: membership_index_fun,
        checkpoint_writer: fn _run_id, _checkpoint ->
          send(test_pid, :projection_checkpoint_written)
          :ok
        end
      )

    assert :ok = CurrentRunProjections.refresh(owner)
    assert_receive :projection_checkpoint_written, 2_000
    outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert :counters.get(counter, 1) == 1
    assert Agent.get(source, &Map.get(&1, :membership_reads, 0)) == 1
    assert Agent.get(source, &Map.get(&1, :merges_reads, 0)) == 1

    send(owner, :clock_tick)

    assert_receive :projection_checkpoint_written, 2_000
    assert is_nil(:sys.get_state(owner).refresh)

    assert Agent.get(source, &Map.get(&1, :membership_reads, 0)) == 1
    assert Agent.get(source, &Map.get(&1, :merges_reads, 0)) == 1
    assert :counters.get(counter, 1) == 1
    assert CurrentRunOutcomeSnapshot.snapshot(server: owner) == outcomes

    assert :ok = CurrentRunProjections.refresh(owner)
    assert :counters.get(counter, 1) == 1

    Agent.update(source, &update_in(&1, [:membership, :generation], fn generation -> generation + 1 end))

    assert :ok = CurrentRunProjections.refresh(owner)
    assert :counters.get(counter, 1) == 2
  end

  test "same-run supervised restart preserves terminal weights and public generations" do
    source = start_supervised!({Agent, fn -> weighted_sources() end})

    checkpoint =
      start_supervised!(Supervisor.child_spec({Agent, fn -> %{} end}, id: unique_name(:checkpoint)))

    pubsub = unique_name(:restart_pubsub)
    name = unique_name(:restart_owner)
    start_supervised!({Phoenix.PubSub, name: pubsub})

    test_pid = self()

    checkpoint_reader = fn ->
      send(test_pid, {:projection_checkpoint_read, self()})
      %{run_id: "run-1", checkpoint: Agent.get(checkpoint, &Map.get(&1, "run-1"))}
    end

    checkpoint_writer = fn run_id, value -> Agent.update(checkpoint, &Map.put(&1, run_id, value)) end

    opts =
      owner_options(source, pubsub,
        name: name,
        checkpoint_reader: checkpoint_reader,
        checkpoint_writer: checkpoint_writer
      )

    {:ok, supervisor} = Supervisor.start_link([{CurrentRunProjections, opts}], strategy: :one_for_one)
    on_exit(fn -> Aiur.TestSupport.safe_stop(supervisor) end)
    assert_receive {:projection_checkpoint_read, initial_owner}, 2_000

    assert :ok = CurrentRunProjections.refresh(name)

    Agent.update(source, fn current ->
      Map.put(current, :status_facts, [List.last(current.status_facts)])
    end)

    assert :ok = CurrentRunProjections.refresh(name)
    before_restart = CurrentRunSummary.snapshot(server: name)

    assert before_restart.weights.eligible == 10
    assert before_restart.weights.successful_terminal == 5
    assert before_restart.weights.remaining == 5
    assert before_restart.progress.exact == %{numerator: 3, denominator: 5}
    assert before_restart.eta.status == :available
    assert before_restart.eta.completed_weight == 5
    assert before_restart.eta.throughput_weight_per_second == %{numerator: 1, denominator: 1_440}

    first_owner = Process.whereis(name)
    assert first_owner == initial_owner
    Process.exit(first_owner, :kill)

    assert_receive {:projection_checkpoint_read, restarted}, 2_000
    assert restarted != first_owner
    assert Process.whereis(name) == restarted

    restored = CurrentRunSummary.snapshot(server: name)
    assert restored.generation == before_restart.generation
    assert restored.denominator.generation == before_restart.denominator.generation

    assert :ok = CurrentRunProjections.refresh(name)
    after_restart = CurrentRunSummary.snapshot(server: name)

    assert after_restart.generation == before_restart.generation
    assert after_restart.denominator == before_restart.denominator
    assert after_restart.weights == before_restart.weights
    assert after_restart.progress == before_restart.progress
    assert after_restart.eta == before_restart.eta
  end

  test "first required-source failure after restart retains the restored projection fence" do
    for {failed_key, checkpoint_shape} <- [
          {:run, :current},
          {:membership, :current},
          {:run, :legacy},
          {:membership, :legacy}
        ] do
      source =
        start_supervised!(
          {Agent, fn -> weighted_sources() end},
          id: unique_name(failed_key)
        )

      checkpoint =
        start_supervised!(Supervisor.child_spec({Agent, fn -> %{} end}, id: unique_name(:restart_failure_checkpoint)))

      pubsub = unique_name(:restart_failure_pubsub)
      name = unique_name(:restart_failure_owner)
      start_supervised!({Phoenix.PubSub, name: pubsub}, id: pubsub)
      test_pid = self()

      checkpoint_reader = fn ->
        send(test_pid, {:projection_checkpoint_read, self()})
        %{run_id: "run-1", checkpoint: Agent.get(checkpoint, &Map.get(&1, "run-1"))}
      end

      checkpoint_writer = fn run_id, value ->
        Agent.update(checkpoint, &Map.put(&1, run_id, value))
        send(test_pid, {:projection_checkpoint_written, run_id, value})
        :ok
      end

      opts =
        owner_options(source, pubsub,
          name: name,
          checkpoint_reader: checkpoint_reader,
          checkpoint_writer: checkpoint_writer
        )

      {:ok, supervisor} = Supervisor.start_link([{CurrentRunProjections, opts}], strategy: :one_for_one)
      on_exit(fn -> Aiur.TestSupport.safe_stop(supervisor) end)
      assert_receive {:projection_checkpoint_read, initial_owner}, 2_000

      assert :ok = CurrentRunProjections.refresh(name)
      assert_receive {:projection_checkpoint_written, "run-1", _checkpoint}, 2_000

      Agent.update(source, fn current ->
        Map.put(current, :status_facts, [List.last(current.status_facts)])
      end)

      assert :ok = CurrentRunProjections.refresh(name)
      assert_receive {:projection_checkpoint_written, "run-1", fenced_checkpoint}, 2_000
      before_restart = CurrentRunSummary.snapshot(server: name)
      assert before_restart.eta.status == :available
      assert length(fenced_checkpoint.sources.membership.members) == 3
      assert length(fenced_checkpoint.units.rows) == 3
      assert fenced_checkpoint.weight_health == :healthy

      if checkpoint_shape == :legacy do
        Agent.update(checkpoint, fn checkpoints ->
          update_in(checkpoints, ["run-1"], fn value ->
            Map.drop(value, [:sources, :availability, :units, :weight_health])
          end)
        end)
      end

      original = Agent.get(source, &Map.fetch!(&1, failed_key))
      Agent.update(source, &Map.put(&1, failed_key, :timeout))
      Process.exit(initial_owner, :kill)

      assert_receive {:projection_checkpoint_read, restarted}, 2_000
      assert restarted != initial_owner
      assert :ok = CurrentRunProjections.refresh(name)

      degraded = CurrentRunSummary.snapshot(server: name)
      degraded_state = :sys.get_state(name)

      if checkpoint_shape == :current do
        assert_receive {:projection_checkpoint_written, "run-1", degraded_checkpoint}, 2_000
        assert degraded.weights == before_restart.weights
        assert degraded.progress.exact == nil
        assert degraded.progress.lower_bound == before_restart.progress.lower_bound
        assert degraded.progress.denominator_weight == before_restart.progress.denominator_weight
        assert degraded.progress.weighted_numerator == before_restart.progress.weighted_numerator
        assert degraded.last_known_good.generation == before_restart.generation
        assert map_size(degraded_state.weight_facts) == 3
        assert length(degraded_state.sources.membership.members) == 3
        assert length(degraded_checkpoint.sources.membership.members) == 3
        assert map_size(degraded_checkpoint.weight_facts) == 3
        refute degraded_state.restore_fence_pending?
      else
        refute_receive {:projection_checkpoint_written, "run-1", _checkpoint}, 50
        assert degraded == before_restart
        assert degraded_state.restore_fence_pending?

        send(name, :clock_tick)
        refute_receive {:projection_checkpoint_written, "run-1", _checkpoint}, 100
        assert CurrentRunSummary.snapshot(server: name) == before_restart
      end

      Agent.update(source, &Map.put(&1, failed_key, original))
      assert :ok = CurrentRunProjections.refresh(name)
      assert_receive {:projection_checkpoint_written, "run-1", _checkpoint}, 2_000

      recovered = CurrentRunSummary.snapshot(server: name)
      assert recovered.weights == before_restart.weights
      assert recovered.progress == before_restart.progress
      assert recovered.eta == before_restart.eta
      refute :sys.get_state(name).restore_fence_pending?

      Supervisor.stop(supervisor)
    end
  end

  test "blocked checkpoint persistence leaves canonical snapshots readable" do
    test_pid = self()

    checkpoint_writer = fn _run_id, checkpoint ->
      send(test_pid, {:projection_checkpoint_blocked, self(), checkpoint.checkpoint_generation})

      receive do
        {:release_projection_checkpoint, result} -> result
      end
    end

    {_source, owner, _pubsub} =
      start_owner(fn value -> value end,
        checkpoint_writer: checkpoint_writer,
        checkpoint_timeout_ms: 2_000
      )

    baseline = CurrentRunSummary.snapshot(server: owner)
    refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)
    assert_receive {:projection_checkpoint_blocked, writer, _generation}, 2_000

    read = Task.async(fn -> CurrentRunSummary.snapshot(server: owner) end)
    assert Task.await(read, 500) == baseline
    assert Process.alive?(owner)
    refute Task.yield(refresh, 0)

    send(writer, {:release_projection_checkpoint, :ok})
    assert Task.await(refresh, 2_000) == :ok
    assert CurrentRunSummary.snapshot(server: owner).health.status == :healthy
  end

  test "checkpoint persistence deadline bounds a blocked writer" do
    test_pid = self()

    checkpoint_writer = fn _run_id, checkpoint ->
      send(test_pid, {:projection_checkpoint_blocked, self(), checkpoint.checkpoint_generation})

      receive do
        :unreachable -> :ok
      end
    end

    {_source, owner, _pubsub} =
      start_owner(fn value -> value end,
        checkpoint_writer: checkpoint_writer,
        checkpoint_timeout_ms: 50
      )

    refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)
    assert_receive {:projection_checkpoint_blocked, writer, _generation}, 2_000
    assert Task.await(refresh, 2_000) == :ok
    refute Process.alive?(writer)

    snapshot = CurrentRunSummary.snapshot(server: owner)
    assert snapshot.generation == 0
    assert snapshot.freshness.status == :stale
    assert :projection_checkpoint_unavailable in snapshot.health.reasons
    assert :sys.get_state(owner).checkpoint_health == {:unavailable, :write_failed}
    assert Process.alive?(owner)
  end

  test "stale checkpoint task outcomes cannot corrupt recovered projection health" do
    test_pid = self()

    checkpoint_writer = fn _run_id, checkpoint ->
      send(test_pid, {:projection_checkpoint_blocked, self(), checkpoint.checkpoint_generation})

      receive do
        {:release_projection_checkpoint, result} -> result
      end
    end

    {source, owner, _pubsub} =
      start_owner(fn value -> value end,
        checkpoint_writer: checkpoint_writer,
        checkpoint_timeout_ms: 2_000
      )

    first_refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)
    assert_receive {:projection_checkpoint_blocked, first_writer, first_generation}, 2_000
    first_write = :sys.get_state(owner).checkpoint_write
    send(first_writer, {:release_projection_checkpoint, {:error, :disk_full}})
    assert Task.await(first_refresh, 2_000) == :ok
    assert :sys.get_state(owner).checkpoint_health == {:unavailable, :write_failed}

    Agent.update(source, &put_in(&1, [:activity, :entries], [activity_entry(identity(), 60)]))
    recovery = Task.async(fn -> CurrentRunProjections.refresh(owner) end)
    assert_receive {:projection_checkpoint_blocked, recovery_writer, recovery_generation}, 2_000
    assert recovery_generation > first_generation
    send(recovery_writer, {:release_projection_checkpoint, :ok})
    assert Task.await(recovery, 2_000) == :ok

    recovered = CurrentRunSummary.snapshot(server: owner)
    assert recovered.health.status == :healthy
    assert recovered.progress.exact == %{numerator: 3, denominator: 5}
    assert :sys.get_state(owner).checkpoint_health == :healthy

    send(owner, {
      :current_run_checkpoint_result,
      first_write.ref,
      first_write.generation,
      {:error, :checkpoint_write_failed}
    })

    assert CurrentRunSummary.snapshot(server: owner) == recovered
    assert :sys.get_state(owner).checkpoint_health == :healthy
  end

  test "failed checkpoints retain the last fenced generation across restart" do
    source = start_supervised!({Agent, fn -> sources() end})

    checkpoint =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{fail?: false, checkpoints: %{}} end},
          id: unique_name(:failing_checkpoint)
        )
      )

    pubsub = unique_name(:failed_checkpoint_pubsub)
    name = unique_name(:failed_checkpoint_owner)
    test_pid = self()
    start_supervised!({Phoenix.PubSub, name: pubsub})

    checkpoint_reader = fn ->
      send(test_pid, {:projection_checkpoint_read, self()})

      %{
        run_id: "run-1",
        checkpoint: Agent.get(checkpoint, &get_in(&1, [:checkpoints, "run-1"]))
      }
    end

    checkpoint_writer = fn run_id, value ->
      Agent.get_and_update(checkpoint, fn
        %{fail?: true} = state ->
          {{:error, :disk_full}, state}

        state ->
          {:ok, put_in(state, [:checkpoints, run_id], value)}
      end)
    end

    opts =
      owner_options(source, pubsub,
        name: name,
        checkpoint_reader: checkpoint_reader,
        checkpoint_writer: checkpoint_writer
      )

    {:ok, supervisor} = Supervisor.start_link([{CurrentRunProjections, opts}], strategy: :one_for_one)
    on_exit(fn -> Aiur.TestSupport.safe_stop(supervisor) end)
    assert_receive {:projection_checkpoint_read, first_owner}, 2_000

    assert :ok = CurrentRunProjections.refresh(name)
    fenced = CurrentRunSummary.snapshot(server: name)
    assert fenced.health.status == :healthy

    Agent.update(source, &put_in(&1, [:activity, :entries], [activity_entry(identity(), 60)]))
    Agent.update(checkpoint, &Map.put(&1, :fail?, true))

    assert :ok = CurrentRunProjections.refresh(name)
    failed_summary = CurrentRunSummary.snapshot(server: name)
    failed_outcomes = CurrentRunOutcomeSnapshot.snapshot(server: name)

    assert failed_summary.generation == fenced.generation
    assert failed_summary.progress == fenced.progress
    assert failed_summary.health.status == :partial
    assert failed_summary.freshness.status == :stale
    assert :projection_checkpoint_unavailable in failed_summary.health.reasons
    assert failed_summary.last_known_good.generation == fenced.generation

    failed_state = :sys.get_state(name)
    assert failed_state.checkpoint_health == {:unavailable, :write_failed}
    assert {^failed_state, false, %{persist?: false}} = Projector.clock(failed_state, %{})

    assert failed_outcomes.health.status == :partial
    assert failed_outcomes.freshness.status == :stale
    assert :projection_checkpoint_unavailable in failed_outcomes.health.reasons

    Process.exit(first_owner, :kill)
    assert_receive {:projection_checkpoint_read, restarted}, 2_000
    assert restarted != first_owner
    assert Process.whereis(name) == restarted

    restored = CurrentRunSummary.snapshot(server: name)
    assert restored.generation == fenced.generation
    assert restored.progress == fenced.progress
    assert restored.health.status == :healthy
    assert :sys.get_state(name).checkpoint_health == :healthy

    Agent.update(checkpoint, &Map.put(&1, :fail?, false))
    assert :ok = CurrentRunProjections.refresh(name)

    recovered = CurrentRunSummary.snapshot(server: name)
    assert recovered.generation > fenced.generation
    assert recovered.progress.exact == %{numerator: 3, denominator: 5}
    assert recovered.health.status == :healthy
  end

  defp start_owner(transform \\ fn value -> value end, extra_opts \\ []) do
    source = start_supervised!({Agent, fn -> transform.(sources()) end})
    pubsub = unique_name(:pubsub)
    start_supervised!({Phoenix.PubSub, name: pubsub})

    owner = start_supervised!({CurrentRunProjections, owner_options(source, pubsub, extra_opts)})

    {source, owner, pubsub}
  end

  defp await_projection_idle(owner, attempts \\ 1_000)

  defp await_projection_idle(_owner, 0), do: flunk("projection owner did not become idle")

  defp await_projection_idle(owner, attempts) do
    state = :sys.get_state(owner)

    if is_nil(state.refresh) and is_nil(state.checkpoint_write) and not state.refresh_pending? do
      :ok
    else
      Process.sleep(5)
      await_projection_idle(owner, attempts - 1)
    end
  end

  defp owner_options(source, pubsub, extra_opts) do
    Keyword.merge(
      [
        name: nil,
        pubsub: pubsub,
        subscribe_funs: [],
        refresh_on_init?: false,
        clock_interval_ms: :infinity,
        reconcile_interval_ms: :infinity,
        run_snapshot_fun: source_reader(source, :run),
        membership_snapshot_fun: source_reader(source, :membership),
        status_snapshot_fun: source_reader(source, :status),
        status_facts_fun: source_reader(source, :status_facts),
        activity_snapshot_fun: source_reader(source, :activity),
        recent_merges_snapshot_fun: source_reader(source, :merges),
        configured_repository_fun: source_reader(source, :configured_repository)
      ],
      extra_opts
    )
  end

  defp source_reader(source, key) do
    fn ->
      value = Agent.get_and_update(source, &read_source(&1, key))
      read_value(value, key)
    end
  end

  defp read_source(sources, key) do
    counter = String.to_atom("#{key}_reads")
    {Map.fetch!(sources, key), Map.update(sources, counter, 1, &(&1 + 1))}
  end

  defp read_value({:block, notify}, key) when is_pid(notify) do
    send(notify, {:projection_reader_blocked, key, self()})

    receive do
      {:release_projection_reader, ^key, value} -> value
    end
  end

  defp read_value(value, _key), do: value

  defp wait_for_refresh_waiters(owner, expected, attempts \\ 1_000)

  defp wait_for_refresh_waiters(_owner, _expected, 0), do: false

  defp wait_for_refresh_waiters(owner, expected, attempts) do
    state = :sys.get_state(owner)
    active = state.refresh |> Map.get(:waiters, []) |> length()
    queued = length(state.queued_waiters)

    if active + queued == expected do
      true
    else
      Process.sleep(1)
      wait_for_refresh_waiters(owner, expected, attempts - 1)
    end
  end

  defp sources do
    ticket = identity()

    %{
      run_reads: 0,
      run: %{
        id: "run-1",
        started_at: ~U[2026-07-17 10:00:00Z],
        observed_at: ~U[2026-07-17 12:00:00Z],
        elapsed_ms: 7_200_000
      },
      membership: %{
        run_id: "run-1",
        generation: 3,
        health: :healthy,
        freshness: %{status: :fresh},
        truncated?: false,
        members: [
          %{
            identity: ticket,
            lifecycle: :running,
            terminal?: false,
            first_observed_at: ~U[2026-07-17 10:00:00Z],
            last_observed_at: ~U[2026-07-17 11:59:00Z]
          }
        ]
      },
      status: %{
        generation: 4,
        running: [
          %{
            tracker_identity: ticket,
            state: "in-progress",
            work_state: :working,
            waiting_reason: :active,
            runtime_seconds: 600,
            open_decision_count: 0
          }
        ],
        retrying: [],
        idle: []
      },
      status_facts: [
        %{
          tracker_identity: ticket,
          title: "Current ticket",
          url: "https://github.com/owner/repo/issues/32",
          state: "in-progress",
          selected_backend: :codex,
          agent_family: :codex,
          requested_model: "gpt-5",
          effort: "high",
          complexity: 3,
          labels: ["complexity:3"]
        }
      ],
      activity: %{generation: 5, entries: [activity_entry(ticket, 40)]},
      merges: %{
        generation: 6,
        health: :writable,
        reconciliation: %{status: :complete, partial?: false, pages_fetched: 1},
        merges: [merge()]
      },
      configured_repository: {:ok, {"owner", "repo"}}
    }
  end

  defp activity_entry(ticket, percent) do
    %{
      identity: ticket,
      progress: %{status: :known, percent: percent, source: :checkin, freshness: :fresh}
    }
  end

  defp weighted_sources do
    first = identity(32)
    second = identity(33)
    active = identity(34)

    sources()
    |> put_in([:membership, :members], [
      member(first, :completed, true),
      member(second, :completed, true),
      member(active, :running, false)
    ])
    |> put_in([:status, :running], [status_row(active)])
    |> put_in([:status_facts], [
      status_fact(first, "done", 2),
      status_fact(second, "done", 3),
      status_fact(active, "in-progress", 5)
    ])
    |> put_in([:activity, :entries], [
      activity_entry(first, 100),
      activity_entry(second, 100),
      activity_entry(active, 20)
    ])
  end

  defp member(ticket, lifecycle, terminal?) do
    %{
      identity: ticket,
      lifecycle: lifecycle,
      terminal?: terminal?,
      first_observed_at: ~U[2026-07-17 10:00:00Z],
      last_observed_at: ~U[2026-07-17 11:59:00Z]
    }
  end

  defp status_row(ticket) do
    %{
      tracker_identity: ticket,
      state: "in-progress",
      work_state: :working,
      waiting_reason: :active,
      runtime_seconds: 600,
      open_decision_count: 0
    }
  end

  defp status_fact(ticket, state, complexity) do
    %{tracker_identity: ticket, state: state, complexity: complexity}
  end

  defp identity(number \\ 32) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "NODE-#{number}",
      identifier: Integer.to_string(number),
      reason: nil
    }
  end

  defp merge do
    merged_at = ~U[2026-07-17 11:00:00Z]

    %RecentMerge{
      id: "owner/repo#32",
      repository: "owner/repo",
      number: 32,
      title: "Projection merge",
      summary: "Projection merge summary",
      url: "https://github.com/owner/repo/pull/32",
      head_ref: "aiur/32-projection",
      head_sha: "head-32",
      merge_commit_sha: "merge-32",
      merged_at: merged_at,
      observation_source: :github_events,
      backfilled?: true,
      live_observed?: false,
      observed_run_id: nil,
      first_observed_at: merged_at,
      last_observed_at: merged_at,
      content_hash: "hash-32"
    }
  end

  defp unique_name(suffix) do
    String.to_atom("current_run_projections_#{suffix}_#{System.unique_integer([:positive])}")
  end
end

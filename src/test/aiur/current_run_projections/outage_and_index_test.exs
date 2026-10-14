defmodule Aiur.CurrentRunProjections.OutageAndIndexTest do
  use ExUnit.Case, async: true

  import Aiur.CurrentRunProjectionsSupport

  alias Aiur.CurrentRunOutcomeSnapshot
  alias Aiur.CurrentRunOutcomeSnapshot.MembershipIndex
  alias Aiur.CurrentRunProjections
  alias Aiur.CurrentRunSummary

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

    Agent.update(source, &update_in(&1, [:run, :elapsed_ms], fn ms -> ms + 1_000 end))
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
end

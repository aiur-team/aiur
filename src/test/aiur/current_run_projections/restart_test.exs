defmodule Aiur.CurrentRunProjections.RestartTest do
  use ExUnit.Case, async: true

  import Aiur.CurrentRunProjectionsSupport

  alias Aiur.CurrentRunOutcomeSnapshot
  alias Aiur.CurrentRunProjections
  alias Aiur.CurrentRunProjections.Projector
  alias Aiur.CurrentRunSummary

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
end

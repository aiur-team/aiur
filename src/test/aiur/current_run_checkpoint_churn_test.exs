defmodule Aiur.CurrentRunCheckpointChurnTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.{CurrentRunProjections, CurrentRunSummary}

  test "identical refreshes write one checkpoint and a changed source writes another" do
    {source, owner, writes} = start_owner()
    for _ <- 1..20, do: assert(:ok = CurrentRunProjections.refresh(owner))
    assert length(Agent.get(writes, & &1)) == 1
    Agent.update(source, &put_in(&1, [:membership, :health], {:unavailable, :test_outage}))
    assert :ok = CurrentRunProjections.refresh(owner)
    assert length(Agent.get(writes, & &1)) == 2
    assert CurrentRunSummary.health(server: owner).status != :healthy
  end

  test "bursts coalesce while changed clock content remains checkpointed" do
    test_pid = self()

    writer = fn _, checkpoint ->
      send(test_pid, {:checkpoint_started, self(), System.monotonic_time(:millisecond), checkpoint.sources.run.elapsed_ms})
      receive_barrier(:release_checkpoint)
      :ok
    end

    {source, owner, _writes} = start_owner(checkpoint_interval_ms: 200, checkpoint_writer: writer)
    initial = Task.async(fn -> CurrentRunProjections.refresh(owner) end)
    {:checkpoint_started, first_writer, first_at, 1_000} = receive_barrier({:checkpoint_started, _, _, 1_000})
    send(first_writer, :release_checkpoint)
    assert Task.await(initial) == :ok
    Agent.update(source, &put_in(&1, [:run, :elapsed_ms], 2_000))
    refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)
    {:checkpoint_started, second_writer, second_at, 2_000} = receive_barrier({:checkpoint_started, _, _, 2_000})
    for _ <- 1..20, do: send(owner, {:status_changed, %{}})
    Agent.update(source, &put_in(&1, [:run, :elapsed_ms], 3_000))
    send(second_writer, :release_checkpoint)
    assert Task.await(refresh) == :ok
    # Only the status events queued during the write may produce this trailing write.
    {:checkpoint_started, final_writer, final_at, 3_000} = receive_barrier({:checkpoint_started, _, _, 3_000})
    send(final_writer, :release_checkpoint)
    assert :ok = CurrentRunProjections.refresh(owner)
    refute_received {:checkpoint_started, _, _, _}
    assert second_at - first_at >= 200
    assert final_at - second_at >= 200
  end

  test "a failed write is retried for identical content" do
    attempts = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :attempts))

    writer = fn _, _ ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 -> {:error, :disk_full}
        _ -> :ok
      end
    end

    {_source, owner, _writes} = start_owner(checkpoint_writer: writer)
    assert :ok = CurrentRunProjections.refresh(owner)
    assert :sys.get_state(owner).checkpoint_health == {:unavailable, :write_failed}
    assert :ok = CurrentRunProjections.refresh(owner)
    assert :sys.get_state(owner).checkpoint_health == :healthy
    assert :ok = CurrentRunProjections.refresh(owner)
    assert Agent.get(attempts, & &1) == 2
  end

  defp start_owner(extra_opts \\ []) do
    source = start_supervised!({Agent, fn -> sources() end})
    writes = start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: :writes))

    writer = fn _, checkpoint ->
      Agent.update(writes, &[{System.monotonic_time(:millisecond), checkpoint} | &1])
    end

    opts = [
      name: nil,
      pubsub: nil,
      subscribe_funs: [],
      task_supervisor: nil,
      refresh_on_init?: false,
      clock_interval_ms: :infinity,
      reconcile_interval_ms: :infinity,
      checkpoint_interval_ms: 10,
      checkpoint_writer: writer
    ]

    readers = [
      run: :run_snapshot_fun,
      membership: :membership_snapshot_fun,
      status: :status_snapshot_fun,
      status_facts: :status_facts_fun,
      activity: :activity_snapshot_fun,
      merges: :recent_merges_snapshot_fun,
      configured_repository: :configured_repository_fun
    ]

    opts =
      Enum.reduce(readers, opts, fn {key, option}, acc ->
        Keyword.put(acc, option, fn -> Agent.get(source, &Map.fetch!(&1, key)) end)
      end)

    owner = start_supervised!({CurrentRunProjections, Keyword.merge(opts, extra_opts)})
    {source, owner, writes}
  end

  defp sources do
    %{
      run: %{id: "churn-run", started_at: ~U[2026-10-08 00:00:00Z], observed_at: ~U[2026-10-08 00:00:01Z], elapsed_ms: 1_000},
      membership: %{run_id: "churn-run", generation: 0, health: :healthy, freshness: %{status: :fresh}, members: [], truncated?: false},
      status: %{running: [], retrying: [], idle: [], health: :healthy, freshness: :fresh},
      status_facts: [],
      activity: %{generation: 0, entries: [], health: :healthy, freshness: :fresh},
      merges: %{generation: 0, merges: [], health: :writable, reconciliation: %{status: :complete, partial?: false, pages_fetched: 1}},
      configured_repository: {:ok, {"aiur-team", "aiur"}}
    }
  end
end

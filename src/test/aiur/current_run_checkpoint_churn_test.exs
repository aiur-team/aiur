defmodule Aiur.CurrentRunCheckpointChurnTest do
  use ExUnit.Case, async: true
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
    {source, owner, writes} = start_owner(checkpoint_interval_ms: 200)
    assert :ok = CurrentRunProjections.refresh(owner)
    Agent.update(source, &put_in(&1, [:run, :elapsed_ms], 2_000))
    refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)
    await_write(owner)
    for _ <- 1..20, do: send(owner, {:status_changed, %{}})
    Agent.update(source, &put_in(&1, [:run, :elapsed_ms], 3_000))
    final_refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)
    assert Task.await(refresh) == :ok
    assert Task.await(final_refresh) == :ok
    checkpoints = Agent.get(writes, &Enum.reverse/1)
    assert length(checkpoints) == 3
    assert Enum.map(checkpoints, fn {_, checkpoint} -> checkpoint.sources.run.elapsed_ms end) == [1_000, 2_000, 3_000]

    for [{earlier, _}, {later, _}] <- Enum.chunk_every(checkpoints, 2, 1, :discard) do
      assert later - earlier >= 200
    end
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

  defp await_write(owner, attempts \\ 1_000)
  defp await_write(_owner, 0), do: flunk("checkpoint did not start")

  defp await_write(owner, attempts) do
    if is_map(:sys.get_state(owner).checkpoint_write) do
      :ok
    else
      Process.sleep(1)
      await_write(owner, attempts - 1)
    end
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

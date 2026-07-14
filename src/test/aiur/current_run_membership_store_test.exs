defmodule Aiur.CurrentRunMembership.StoreTest do
  use ExUnit.Case, async: false

  alias Aiur.{CurrentRunMembership, DecisionLog, TrackerIdentity}
  alias Aiur.CurrentRunMembership.{Event, Store}

  @run_id "membership-store-test"
  @now ~U[2026-07-14 12:00:00Z]

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-current-run-membership-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "persists queue and terminal membership before publishing a restart-safe generation", %{dir: dir} do
    pid = start_store!(dir)
    issue = identity()

    assert {:ok, %{status: :accepted, generation: 1}} = observe(pid, issue, :queued)
    assert {:ok, %{status: :accepted, generation: 2}} = observe(pid, issue, :completed, 1)
    assert {:ok, %{status: :terminal, generation: 2}} = observe(pid, issue, :retrying, 2)
    assert %{generation: 2, health: :healthy, members: [%{lifecycle: :completed, terminal?: true}]} = Store.snapshot(server: pid)

    crash(pid)
    recovered = start_store!(dir)

    assert %{generation: 2, health: :healthy, members: [%{lifecycle: :completed, terminal?: true}]} = Store.snapshot(server: recovered)
  end

  test "publishes the durable accepted membership fact over the headless PubSub API", %{dir: dir} do
    assert :ok = CurrentRunMembership.subscribe()
    on_exit(fn -> Phoenix.PubSub.unsubscribe(Aiur.PubSub, "current-run-membership:changed") end)

    pid = start_store!(dir)
    assert {:ok, %{status: :accepted, generation: 1}} = observe(pid, identity(), :queued)

    assert_receive {:current_run_membership_changed, %{run_id: @run_id, generation: 1, event: %{lifecycle: :queued}, health: :healthy}}
  end

  test "same-run recovery replays an acknowledged journal prefix and repairs a torn tail", %{dir: dir} do
    pid = start_store!(dir)
    issue = identity()
    assert {:ok, %{generation: 1}} = observe(pid, issue, :queued)
    stop(pid)

    journal = journal_path(dir)
    {:ok, running} = Event.new(@run_id, issue, :running, DateTime.add(@now, 1, :second))
    assert :ok = DecisionLog.append(journal, Event.to_record(running))
    assert :ok = File.write(journal, ~s({"incomplete":), [:append])

    recovered = start_store!(dir)

    assert %{generation: 2, health: :healthy, members: [%{lifecycle: :running}]} = Store.snapshot(server: recovered)
    assert String.ends_with?(File.read!(journal), "\n")
  end

  test "a new run cannot inherit a prior run's members", %{dir: dir} do
    first = start_store!(dir, @run_id)
    assert {:ok, %{generation: 1}} = observe(first, identity(), :queued)
    stop(first)

    second = start_store!(dir, "membership-store-next-run")
    assert %{run_id: "membership-store-next-run", generation: 0, health: :healthy, members: []} = Store.snapshot(server: second)
    assert [run_dir] = Path.wildcard(Path.join([dir, "runs", "*"]))
    assert File.dir?(run_dir)
  end

  test "corrupt checkpoint is quarantined and never presented as a healthy empty membership set", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, _} = observe(pid, identity(), :queued)
    stop(pid)

    checkpoint = checkpoint_path(dir)
    assert :ok = File.write(checkpoint, "{")

    recovered = start_store!(dir)
    snapshot = Store.snapshot(server: recovered)

    assert {:degraded, {:checkpoint_corrupt, _reason}} = snapshot.health
    assert snapshot.members == []
    assert snapshot.health_message =~ "degraded"
    assert [{_quarantined, _}] = Path.wildcard(checkpoint <> ".corrupt-*") |> Enum.map(&{&1, File.stat!(&1)})
  end

  test "corrupt journal preserves the checkpoint projection but marks recovery degraded", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, _} = observe(pid, identity(), :queued)
    stop(pid)

    assert :ok = File.write(journal_path(dir), "not-json\n")
    recovered = start_store!(dir)

    assert %{health: {:degraded, {:journal_corrupt, 1, _reason}}, members: [%{lifecycle: :queued}]} = Store.snapshot(server: recovered)
    assert {:error, {:membership_unavailable, {:degraded, _reason}}} = observe(recovered, identity(), :running, 1)
  end

  test "append failure leaves the last known good generation unchanged and can recover on retry", %{dir: dir} do
    {:ok, mode} = Agent.start_link(fn -> :fail end)

    append_fun = fn path, record ->
      if Agent.get(mode, & &1) == :ok, do: DecisionLog.append(path, record), else: {:error, :disk_full}
    end

    pid = start_store!(dir, @run_id, append_fun: append_fun)

    assert {:error, {:membership_persistence_failed, {:append_failed, :disk_full}}} = observe(pid, identity(), :queued)
    assert %{generation: 0, members: [], health: {:degraded, {:append_failed, :disk_full}}} = Store.snapshot(server: pid)

    Agent.update(mode, fn _ -> :ok end)
    assert {:ok, %{generation: 1}} = observe(pid, identity(), :queued)
    assert %{generation: 1, health: :healthy} = Store.snapshot(server: pid)
  end

  test "checkpoint failure retains the previous generation until replay can safely restore the durable journal", %{dir: dir} do
    pid = start_store!(dir, @run_id, checkpoint_fun: fn _path, _record -> {:error, :rename_failed} end)

    assert {:error, {:membership_persistence_failed, {:checkpoint_failed, :rename_failed}}} = observe(pid, identity(), :queued)
    assert %{generation: 0, members: [], health: {:degraded, {:checkpoint_failed, :rename_failed}}} = Store.snapshot(server: pid)
    stop(pid)

    recovered = start_store!(dir)
    assert %{generation: 1, health: :healthy, members: [%{lifecycle: :queued}]} = Store.snapshot(server: recovered)
  end

  test "first checkpoint directory entry is synced before its journal can be cleared", %{dir: dir} do
    {:ok, sync_count} = Agent.start_link(fn -> 0 end)

    sync_fun = fn ->
      case Agent.get_and_update(sync_count, fn count -> {count, count + 1} end) do
        0 -> :ok
        _ -> {:error, :sync_failed}
      end
    end

    pid = start_store!(dir, @run_id, filesystem_sync_fun: sync_fun)

    assert {:error, {:membership_persistence_failed, {:checkpoint_entry_sync_failed, :sync_failed}}} = observe(pid, identity(), :queued)

    assert %{generation: 0, members: [], health: {:degraded, {:checkpoint_entry_sync_failed, :sync_failed}}} =
             Store.snapshot(server: pid)

    stop(pid)
    recovered = start_store!(dir)
    assert %{generation: 1, health: :healthy, members: [%{lifecycle: :queued}]} = Store.snapshot(server: recovered)
  end

  test "invalid run IDs remain unavailable instead of crashing the projection", %{dir: dir} do
    assert {:ok, pid} = Store.start_link(name: nil, state_dir: dir, run_id: :invalid)
    assert {:unavailable, {:prepare_failed, :invalid_run_id}} = Store.health(pid)
  end

  test "obsolete generation cleanup trouble stays visibly degraded while current observations persist", %{dir: dir} do
    pid = start_store!(dir, @run_id, cleanup_fun: fn _runs_dir, _active_leaf -> {:error, :permission_denied} end)

    assert %{health: {:degraded, {:cleanup_failed, :permission_denied}}} = Store.snapshot(server: pid)
    assert {:ok, %{status: :accepted, generation: 1}} = observe(pid, identity(), :queued)

    assert %{health: {:degraded, {:cleanup_failed, :permission_denied}}, members: [%{lifecycle: :queued}]} =
             Store.snapshot(server: pid)
  end

  test "a process crash after the fsynced append and before checkpoint replay recovers the accepted member", %{dir: dir} do
    parent = self()

    pid =
      start_store!(dir, @run_id,
        checkpoint_fun: fn _path, _record ->
          send(parent, :checkpoint_started)

          receive do
            :finish_checkpoint -> :ok
          end
        end
      )

    {:ok, task} = Task.start(fn -> Store.observe(identity(), :queued, server: pid, observed_at: @now) end)
    assert_receive :checkpoint_started
    task_ref = Process.monitor(task)
    crash(pid)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}

    recovered = start_store!(dir)
    assert %{generation: 1, health: :healthy, members: [%{lifecycle: :queued}]} = Store.snapshot(server: recovered)
  end

  test "snapshot is bounded and lookup uses the full repository-qualified identity", %{dir: dir} do
    pid = start_store!(dir)
    first = identity("owner-a", "repo-a", "I-42", "42")
    second = identity("owner-b", "repo-b", "I-42", "42")
    assert {:ok, _} = observe(pid, first, :queued)
    assert {:ok, _} = observe(pid, second, :paused, 1)

    assert %{members: [member], truncated?: true} = Store.snapshot(server: pid, limit: 1)
    assert member.identity.owner == "owner-a"
    assert {:ok, %{identity: ^second, lifecycle: :paused}} = Store.lookup(second, pid)
  end

  test "recovery files are owner-only and contain no tracker content", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, _} = observe(pid, identity(), :waiting)

    for path <- [checkpoint_path(dir), journal_path(dir)] do
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      refute File.read!(path) =~ "ticket title"
      refute File.read!(path) =~ "ghp_"
    end

    for path <- [dir, Path.join(dir, "runs"), Path.dirname(checkpoint_path(dir))] do
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o700
    end
  end

  defp start_store!(dir, run_id \\ @run_id, opts \\ []) do
    {:ok, pid} = Store.start_link(Keyword.merge([name: nil, state_dir: dir, run_id: run_id], opts))
    pid
  end

  defp observe(pid, identity, lifecycle, seconds \\ 0) do
    Store.observe(identity, lifecycle, server: pid, observed_at: DateTime.add(@now, seconds, :second))
  end

  defp identity(owner \\ "owner", repository \\ "repo", provider_id \\ "I-42", identifier \\ "42") do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: repository,
      provider_id: provider_id,
      identifier: identifier,
      reason: nil
    }
  end

  defp checkpoint_path(dir), do: only_path(dir, "membership.checkpoint.json")
  defp journal_path(dir), do: only_path(dir, "membership.ndjson")

  defp only_path(dir, filename) do
    [path] = Path.wildcard(Path.join([dir, "runs", "*", filename]))
    path
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp crash(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end

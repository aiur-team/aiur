defmodule Aiur.CurrentRunMembership.StorePersistenceTest do
  use ExUnit.Case, async: false

  import Aiur.CurrentRunMembershipStoreSupport

  alias Aiur.CurrentRunMembership
  alias Aiur.CurrentRunMembership.Event
  alias Aiur.CurrentRunMembership.Store
  alias Aiur.CurrentRunMembership.Store.TerminalVerification
  alias Aiur.Journal

  @run_id "membership-store-test"
  @now ~U[2026-07-14 12:00:00Z]

  setup do
    # The tests subscribe to the shared `Aiur.PubSub` registry, an app child a
    # sibling test can terminate. Ensure it is running before subscribing —
    # a missing registry raises `unknown registry: Aiur.PubSub` instead of
    # failing the assertion the test is actually about (#2397).
    :ok = Aiur.TestSupport.ensure_pubsub_running()

    dir = Aiur.TestSupport.tmp_root!("aiur-current-run-membership")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "persists queue and terminal membership before publishing a restart-safe generation", %{dir: dir} do
    pid = start_store!(dir)
    issue = %{identity() | database_id: 84}

    assert {:ok, %{status: :accepted, generation: 1}} = observe(pid, issue, :queued)
    assert {:ok, %{status: :accepted, generation: 2}} = observe(pid, issue, :completed, 1)
    assert {:ok, %{status: :terminal, generation: 2}} = observe(pid, issue, :retrying, 2)

    assert %{
             generation: 2,
             health: :healthy,
             members: [%{identity: ^issue, lifecycle: :completed, terminal?: true}]
           } =
             Store.snapshot(server: pid)

    crash(pid)
    recovered = start_store!(dir)

    assert %{
             generation: 2,
             health: :healthy,
             members: [%{identity: ^issue, lifecycle: :completed, terminal?: true}]
           } =
             Store.snapshot(server: recovered)
  end

  test "publishes the durable accepted membership fact over the headless PubSub API", %{dir: dir} do
    assert :ok = CurrentRunMembership.subscribe()
    on_exit(fn -> Phoenix.PubSub.unsubscribe(Aiur.PubSub, "current-run-membership:changed") end)

    pid = start_store!(dir)
    assert {:ok, %{status: :accepted, generation: 1}} = observe(pid, identity(), :queued)

    assert_receive {:current_run_membership_changed, payload}, 1000
    assert payload.run_id == @run_id
    assert payload.generation == 1
    assert payload.event.lifecycle == :queued
    assert payload.health == :healthy
    assert %{status: _status} = payload.freshness
  end

  test "holds a run-fenced projection checkpoint across membership updates", %{dir: dir} do
    pid = start_store!(dir)
    checkpoint = %{summary_generation: 7, weight_facts: %{{:github, "owner", "repo", "32"} => 3}}

    assert %{run_id: @run_id, checkpoint: nil} = Store.projection_checkpoint(pid)
    assert :ok = Store.put_projection_checkpoint(@run_id, checkpoint, pid)
    assert {:ok, %{generation: 1}} = observe(pid, identity(), :queued)
    assert :ok = Store.mark_reconciled(:fresh, pid)
    assert %{run_id: @run_id, checkpoint: ^checkpoint} = Store.projection_checkpoint(pid)

    assert {:error, :different_run} =
             Store.put_projection_checkpoint("another-run", %{summary_generation: 99}, pid)

    assert %{run_id: @run_id, checkpoint: ^checkpoint} = Store.projection_checkpoint(pid)
  end

  test "stale projection checkpoint generations cannot overwrite newer state", %{dir: dir} do
    pid = start_store!(dir)
    newer = %{checkpoint_generation: 20, summary_generation: 8}
    stale = %{checkpoint_generation: 19, summary_generation: 7}

    assert :ok = Store.put_projection_checkpoint(@run_id, newer, pid)
    assert :ok = Store.put_projection_checkpoint(@run_id, stale, pid)
    assert %{run_id: @run_id, checkpoint: ^newer} = Store.projection_checkpoint(pid)
  end

  test "expired projection checkpoint tasks cannot mutate store state", %{dir: dir} do
    pid = start_store!(dir)

    expired = %{
      checkpoint_generation: 20,
      checkpoint_deadline_monotonic_ms: System.monotonic_time(:millisecond) - 1,
      summary_generation: 8
    }

    assert {:error, :checkpoint_expired} = Store.put_projection_checkpoint_fenced(@run_id, expired, pid)
    assert %{run_id: @run_id, checkpoint: nil} = Store.projection_checkpoint(pid)
  end

  test "compacts after a bounded journal cadence instead of syncing the filesystem per observation", %{dir: dir} do
    {:ok, sync_count} = Agent.start_link(fn -> 0 end)

    sync_fun = fn ->
      Agent.update(sync_count, &(&1 + 1))
      :ok
    end

    pid = start_store!(dir, @run_id, checkpoint_interval: 2, filesystem_sync_fun: sync_fun)

    assert {:ok, %{generation: 1}} = observe(pid, identity(), :queued)
    assert Agent.get(sync_count, & &1) == 1
    refute File.exists?(Path.join(Path.dirname(journal_path(dir)), "membership.checkpoint.json"))
    assert File.read!(journal_path(dir)) != ""

    assert {:ok, %{generation: 2}} = observe(pid, identity(), :running, 1)
    assert Agent.get(sync_count, & &1) == 2
    assert File.read!(journal_path(dir)) == ""
  end

  test "same-run recovery replays an acknowledged journal prefix and repairs a torn tail", %{dir: dir} do
    pid = start_store!(dir)
    issue = identity()
    assert {:ok, %{generation: 1}} = observe(pid, issue, :queued)
    stop(pid)

    journal = journal_path(dir)
    {:ok, running} = Event.new(@run_id, issue, :running, DateTime.add(@now, 1, :second))
    assert :ok = Journal.append(journal, Event.to_record(running))
    assert :ok = File.write(journal, ~s({"incomplete":), [:append])

    recovered = start_store!(dir)

    assert %{generation: 2, health: :healthy, members: [%{lifecycle: :running}]} = Store.snapshot(server: recovered)
    assert String.ends_with?(File.read!(journal), "\n")
  end

  test "freshness distinguishes recovered membership from unavailable and fresh source observations", %{dir: dir} do
    first = start_store!(dir)
    assert {:ok, %{generation: 1}} = observe(first, identity(), :queued)
    stop(first)

    recovered = start_store!(dir)
    assert %{freshness: %{status: :stale, reconciled_at: nil}, members: [_]} = Store.snapshot(server: recovered)

    assert :ok = Store.mark_reconciled(:unavailable, recovered)
    assert %{freshness: %{status: :unavailable, reconciled_at: %DateTime{}}} = Store.snapshot(server: recovered)

    assert :ok = Store.mark_reconciled(:fresh, recovered)
    assert %{freshness: %{status: :fresh}, members: [_]} = Store.snapshot(server: recovered)
  end

  test "freshness records every completed reconciliation even when its status is unchanged", %{dir: dir} do
    {:ok, clock} = Agent.start_link(fn -> @now end)
    clock_fun = fn -> Agent.get(clock, & &1) end
    pid = start_store!(dir, @run_id, clock: clock_fun)

    assert :ok = Store.mark_reconciled(:fresh, pid)
    assert %{freshness: %{reconciled_at: @now}} = Store.snapshot(server: pid)

    later = DateTime.add(@now, 1, :second)
    Agent.update(clock, fn _ -> later end)

    assert :ok = Store.mark_reconciled(:fresh, pid)
    assert %{freshness: %{reconciled_at: ^later}} = Store.snapshot(server: pid)
  end

  test "pending terminal verification prevents a generic reconciliation from reporting fresh", %{dir: dir} do
    pid = start_store!(dir)

    assert :ok = Store.set_terminal_verification_pending(identity(), true, pid)
    assert :ok = Store.mark_reconciled(:fresh, pid)

    assert %{freshness: %{status: :unavailable, terminal_verification_pending?: true}} =
             Store.snapshot(server: pid)

    assert :ok = Store.set_terminal_verification_pending(identity(), false, pid)
    assert :ok = Store.mark_reconciled(:fresh, pid)
    assert %{freshness: %{status: :fresh, terminal_verification_pending?: false}} = Store.snapshot(server: pid)
  end

  test "pending terminal verification survives a membership process restart", %{dir: dir} do
    first = start_store!(dir)
    assert :ok = Store.set_terminal_verification_pending(identity(), true, first)
    stop(first)

    recovered = start_store!(dir)
    assert :ok = Store.mark_reconciled(:fresh, recovered)

    assert %{freshness: %{status: :unavailable, terminal_verification_pending?: true}} =
             Store.snapshot(server: recovered)
  end

  test "a successful retry repairs a multi-key marker after acknowledgement loss", %{dir: dir} do
    {:ok, writes} = Agent.start_link(fn -> 0 end)

    marker_fun = fn path, run_id, pending_keys, sync_fun ->
      case Agent.get_and_update(writes, fn count -> {count, count + 1} end) do
        1 ->
          assert :ok = TerminalVerification.write(path, run_id, pending_keys, sync_fun)
          {:error, :acknowledgement_lost}

        _ ->
          TerminalVerification.write(path, run_id, pending_keys, sync_fun)
      end
    end

    pid = start_store!(dir, @run_id, terminal_verification_marker_fun: marker_fun)
    first = identity("owner", "repo", "I-first", "1")
    second = identity("owner", "repo", "I-second", "2")

    assert :ok = Store.set_terminal_verification_pending(first, true, pid)

    assert {:error, :terminal_verification_marker_failed} =
             Store.set_terminal_verification_pending(second, true, pid)

    assert Agent.get(writes, & &1) == 2
    assert :ok = Store.set_terminal_verification_pending(second, false, pid)
    assert Agent.get(writes, & &1) == 3

    assert %{health: :healthy, freshness: %{terminal_verification_pending?: true}} =
             Store.snapshot(server: pid)

    stop(pid)

    recovered = start_store!(dir)
    assert :ok = Store.mark_reconciled(:fresh, recovered)

    assert %{freshness: %{status: :unavailable, terminal_verification_pending?: true}} =
             Store.snapshot(server: recovered)

    assert :ok = Store.set_terminal_verification_pending(first, false, recovered)
    assert :ok = Store.mark_reconciled(:fresh, recovered)

    assert %{freshness: %{status: :fresh, terminal_verification_pending?: false}} =
             Store.snapshot(server: recovered)
  end

  test "terminal marker repair preserves unrelated degraded health", %{dir: dir} do
    {:ok, writes} = Agent.start_link(fn -> 0 end)

    marker_fun = fn path, run_id, pending_keys, sync_fun ->
      case Agent.get_and_update(writes, fn count -> {count, count + 1} end) do
        0 ->
          assert :ok = TerminalVerification.write(path, run_id, pending_keys, sync_fun)
          {:error, :acknowledgement_lost}

        _ ->
          TerminalVerification.write(path, run_id, pending_keys, sync_fun)
      end
    end

    pid =
      start_store!(dir, @run_id,
        cleanup_fun: fn _runs_dir, _active_leaf -> {:error, :permission_denied} end,
        terminal_verification_marker_fun: marker_fun
      )

    assert {:error, :terminal_verification_marker_failed} =
             Store.set_terminal_verification_pending(identity(), true, pid)

    assert :ok = Store.set_terminal_verification_pending(identity(), true, pid)

    assert %{health: {:degraded, {:cleanup_failed, :permission_denied}}} =
             Store.snapshot(server: pid)
  end

  test "resolving another terminal identity cannot clear an outstanding verification", %{dir: dir} do
    first = identity("owner", "repo", "I-first", "1")
    second = identity("owner", "repo", "I-second", "2")
    pid = start_store!(dir)

    assert :ok = Store.set_terminal_verification_pending(first, true, pid)
    assert :ok = Store.set_terminal_verification_pending(second, true, pid)
    assert :ok = Store.set_terminal_verification_pending(second, false, pid)
    assert :ok = Store.mark_reconciled(:fresh, pid)

    assert %{freshness: %{status: :unavailable, terminal_verification_pending?: true}} =
             Store.snapshot(server: pid)

    crash(pid)
    recovered = start_store!(dir)
    assert :ok = Store.mark_reconciled(:fresh, recovered)

    assert %{freshness: %{status: :unavailable, terminal_verification_pending?: true}} =
             Store.snapshot(server: recovered)
  end

  test "a new run cannot inherit a prior run's members", %{dir: dir} do
    first = start_store!(dir, @run_id)
    assert {:ok, %{generation: 1}} = observe(first, identity(), :queued)
    stop(first)

    second = start_store!(dir, "membership-store-next-run")

    assert %{run_id: "membership-store-next-run", generation: 0, health: :healthy, members: []} =
             Store.snapshot(server: second)

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
end

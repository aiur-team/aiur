defmodule Aiur.CurrentRunMembership.StoreTest do
  use ExUnit.Case, async: false

  alias Aiur.{CurrentRunMembership, DecisionLog, TrackerIdentity}
  alias Aiur.CurrentRunMembership.{Event, Store}
  alias Aiur.CurrentRunMembership.Store.TerminalVerification

  @run_id "membership-store-test"
  @now ~U[2026-07-14 12:00:00Z]
  @async_assert_timeout 2_000

  setup do
    # The tests subscribe to the shared `Aiur.PubSub` registry, an app child a
    # sibling test can terminate. Ensure it is running before subscribing —
    # a missing registry raises `unknown registry: Aiur.PubSub` instead of
    # failing the assertion the test is actually about (#2397).
    :ok = Aiur.TestSupport.ensure_pubsub_running()

    dir = Path.join(System.tmp_dir!(), "aiur-current-run-membership-#{System.unique_integer([:positive])}")
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

    assert_receive {:current_run_membership_changed, payload}
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
    assert :ok = DecisionLog.append(journal, Event.to_record(running))
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

  test "corrupt checkpoint replays its valid journal while retaining degraded recovery health", %{dir: dir} do
    pid = start_store!(dir, @run_id, clear_journal_fun: fn _path -> {:error, :compaction_failed} end)
    assert {:ok, %{generation: 1}} = observe(pid, identity(), :queued)
    stop(pid)

    checkpoint = checkpoint_path(dir)
    assert :ok = File.write(checkpoint, "{")

    recovered = start_store!(dir)

    assert %{generation: 1, health: {:degraded, {:checkpoint_corrupt, _reason}}, members: [member]} =
             Store.snapshot(server: recovered)

    assert member.lifecycle == :queued
  end

  test "corrupt recovery contents never reach health or PubSub", %{dir: dir} do
    first = start_store!(dir)
    assert {:ok, _} = observe(first, identity(), :queued)
    stop(first)

    sentinel = "ghp_checkpoint_recovery_sentinel"
    assert :ok = File.write(checkpoint_path(dir), "{\"contents\":\"#{sentinel}\"")

    assert :ok = CurrentRunMembership.subscribe()
    on_exit(fn -> Phoenix.PubSub.unsubscribe(Aiur.PubSub, "current-run-membership:changed") end)

    recovered = start_store!(dir)
    snapshot = Store.snapshot(server: recovered)

    assert_receive {:current_run_membership_health_changed, payload}

    for public_surface <- [snapshot, Store.health(recovered), payload] do
      refute inspect(public_surface) =~ sentinel
    end
  end

  test "corrupt journal contents never reach health or PubSub", %{dir: dir} do
    first = start_store!(dir)
    assert {:ok, _} = observe(first, identity(), :queued)
    stop(first)

    sentinel = "ghp_journal_recovery_sentinel"
    assert :ok = File.write(journal_path(dir), "{\"contents\":\"#{sentinel}\"}\n")

    assert :ok = CurrentRunMembership.subscribe()
    on_exit(fn -> Phoenix.PubSub.unsubscribe(Aiur.PubSub, "current-run-membership:changed") end)

    recovered = start_store!(dir)
    snapshot = Store.snapshot(server: recovered)

    assert_receive {:current_run_membership_health_changed, payload}

    for public_surface <- [snapshot, Store.health(recovered), payload] do
      refute inspect(public_surface) =~ sentinel
    end
  end

  test "oversized journal records are rejected before JSON decoding", %{dir: dir} do
    first = start_store!(dir)
    assert {:ok, _} = observe(first, identity(), :queued)
    stop(first)

    oversized_record = String.duplicate("x", 4_097) <> "\n"
    assert :ok = File.write(journal_path(dir), oversized_record)

    recovered = start_store!(dir)

    assert %{health: {:degraded, {:journal_corrupt, 1, :record_too_large}}} =
             Store.snapshot(server: recovered)
  end

  test "a failed degraded marker write preserves a corrupt checkpoint across later restarts", %{dir: dir} do
    first = start_store!(dir)
    assert {:ok, %{generation: 1}} = observe(first, identity(), :queued)
    stop(first)

    checkpoint = checkpoint_path(dir)
    assert :ok = File.write(checkpoint, "{")

    failed =
      start_store!(dir, @run_id,
        filesystem_sync_fun: fn -> :ok end,
        degraded_marker_fun: fn _path, _run_id, _reason, _sync_fun ->
          {:error, :injected_marker_write_failure}
        end
      )

    assert %{health: {:unavailable, {:degraded_marker_failed, :injected_marker_write_failure}}} =
             Store.snapshot(server: failed)

    assert File.exists?(checkpoint)
    stop(failed)

    recovered_once = start_store!(dir, @run_id, filesystem_sync_fun: fn -> :ok end)
    assert %{health: {:degraded, _reason}, members: []} = Store.snapshot(server: recovered_once)
    stop(recovered_once)

    recovered_twice = start_store!(dir, @run_id, filesystem_sync_fun: fn -> :ok end)
    assert %{health: {:degraded, _reason}, members: []} = Store.snapshot(server: recovered_twice)
  end

  test "corrupt journal preserves the checkpoint projection but marks recovery degraded", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, _} = observe(pid, identity(), :queued)
    stop(pid)

    assert :ok = File.write(journal_path(dir), "not-json\n")
    recovered = start_store!(dir)

    assert %{health: {:degraded, {:journal_corrupt, 1, _reason}}, members: [%{lifecycle: :queued}]} =
             Store.snapshot(server: recovered)

    assert {:error, {:membership_unavailable, {:degraded, _reason}}} = observe(recovered, identity(), :running, 1)
  end

  test "an interior blank journal record is quarantined instead of reporting healthy recovery", %{dir: dir} do
    pid = start_store!(dir, @run_id, clear_journal_fun: fn _path -> {:error, :compaction_failed} end)
    assert {:ok, _} = observe(pid, identity(), :queued)
    stop(pid)

    journal = journal_path(dir)
    assert :ok = File.write(journal, "\n", [:append])

    recovered = start_store!(dir)

    assert %{health: {:degraded, {:journal_corrupt, 2, _reason}}, members: [%{lifecycle: :queued}]} =
             Store.snapshot(server: recovered)

    assert [_quarantined] = Path.wildcard(journal <> ".corrupt-*")
  end

  test "a corrupt journal checkpoints its validated prefix before quarantine across two restarts", %{dir: dir} do
    first = start_store!(dir, @run_id, checkpoint_interval: 32)
    assert {:ok, %{generation: 1}} = observe(first, identity(), :queued)
    stop(first)

    journal = journal_path(dir)
    assert :ok = File.write(journal, "not-json\n", [:append])

    recovered_once = start_store!(dir, @run_id, checkpoint_interval: 32)

    assert %{generation: 1, health: {:degraded, _reason}, members: [%{lifecycle: :queued}]} =
             Store.snapshot(server: recovered_once)

    stop(recovered_once)
    recovered_twice = start_store!(dir, @run_id, checkpoint_interval: 32)

    assert %{generation: 1, health: {:degraded, _reason}, members: [%{lifecycle: :queued}]} =
             Store.snapshot(server: recovered_twice)
  end

  test "checkpoint recovery rejects a checksummed member with content-bearing extra keys", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, %{generation: 1}} = observe(pid, identity(), :queued)
    stop(pid)

    checkpoint = checkpoint_path(dir)
    record = Jason.decode!(File.read!(checkpoint))
    [member] = record["members"]
    record = Map.put(record, "members", [Map.put(member, "title", "must not persist")])
    record = Map.put(record, "checksum", checkpoint_checksum(record))
    assert :ok = File.write(checkpoint, Jason.encode!(record))

    recovered = start_store!(dir)

    assert %{health: {:degraded, {:checkpoint_corrupt, :invalid_checkpoint}}, members: []} =
             Store.snapshot(server: recovered)

    assert [_quarantined] = Path.wildcard(checkpoint <> ".corrupt-*")
  end

  test "an invalid degraded marker never exposes its content through public health", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, %{generation: 1}} = observe(pid, identity(), :queued)
    stop(pid)

    marker = Path.join(Path.dirname(checkpoint_path(dir)), "membership.degraded.json")

    marker_record = %{
      "version" => 1,
      "run_id" => @run_id,
      "reason" => "ghp_credential_shaped_sentinel",
      "title" => "private title"
    }

    assert :ok = File.write(marker, Jason.encode!(marker_record))

    recovered = start_store!(dir)
    snapshot = Store.snapshot(server: recovered)

    assert snapshot.health == {:unavailable, :recovery_unavailable}
    assert snapshot.health_message == "current-run membership is unavailable"
    refute snapshot.health_message =~ "ghp_"
    refute snapshot.health_message =~ "private title"
  end

  test "an oversized terminal-verification marker is unavailable without exposing its contents", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, _} = observe(pid, identity(), :queued)
    stop(pid)

    sentinel = "ghp_terminal_verification_sentinel"
    marker = Path.join(Path.dirname(checkpoint_path(dir)), "membership.terminal-verification.json")
    assert :ok = File.write(marker, String.duplicate(sentinel, 200))

    recovered = start_store!(dir)
    snapshot = Store.snapshot(server: recovered)

    assert snapshot.health == {:unavailable, :terminal_verification_marker_too_large}
    refute inspect(snapshot) =~ sentinel
  end

  test "append failure leaves membership read-only until recovery validates the journal", %{dir: dir} do
    {:ok, mode} = Agent.start_link(fn -> :fail end)

    append_fun = fn path, record ->
      if Agent.get(mode, & &1) == :ok, do: DecisionLog.append(path, record), else: {:error, :disk_full}
    end

    pid = start_store!(dir, @run_id, append_fun: append_fun)

    assert {:error, {:membership_persistence_failed, {:append_failed, :disk_full}}} = observe(pid, identity(), :queued)

    assert %{generation: 0, members: [], health: {:degraded, {:append_failed, :disk_full}}} =
             Store.snapshot(server: pid)

    Agent.update(mode, fn _ -> :ok end)

    assert {:error, {:membership_unavailable, {:degraded, {:append_failed, :disk_full}}}} =
             observe(pid, identity(), :queued)

    stop(pid)
    recovered = start_store!(dir)
    assert {:ok, %{generation: 1}} = observe(recovered, identity(), :queued)
    assert %{generation: 1, health: :healthy} = Store.snapshot(server: recovered)
  end

  test "an ambiguous append failure is replayed before another transition can compact it", %{dir: dir} do
    append_fun = fn path, record ->
      :ok = DecisionLog.append(path, record)
      {:error, :acknowledgement_lost}
    end

    pid = start_store!(dir, @run_id, append_fun: append_fun)

    assert {:error, {:membership_persistence_failed, {:append_failed, :acknowledgement_lost}}} =
             observe(pid, identity(), :queued)

    assert {:error, {:membership_unavailable, {:degraded, {:append_failed, :acknowledgement_lost}}}} =
             observe(pid, identity("owner", "repo", "I-next"), :running)

    stop(pid)
    recovered = start_store!(dir)

    assert %{generation: 1, health: :healthy, members: [%{lifecycle: :queued}]} =
             Store.snapshot(server: recovered)
  end

  test "journal compaction failure retains a replayable event without duplicating membership", %{dir: dir} do
    pid = start_store!(dir, @run_id, clear_journal_fun: fn _path -> {:error, :compaction_failed} end)

    assert {:ok, %{generation: 1}} = observe(pid, identity(), :queued)
    assert %{health: {:degraded, {:journal_compaction_failed, :compaction_failed}}} = Store.snapshot(server: pid)
    journal = File.read!(journal_path(dir))

    assert {:error, {:membership_unavailable, {:degraded, {:journal_compaction_failed, :compaction_failed}}}} =
             observe(pid, identity("owner", "repo", "I-next", "43"), :queued, 1)

    assert File.read!(journal_path(dir)) == journal
    stop(pid)

    recovered = start_store!(dir)

    assert %{generation: 1, health: :healthy, members: [%{lifecycle: :queued}]} =
             Store.snapshot(server: recovered)
  end

  test "checkpoint failure retains its previous generation through a durable journal replay", %{dir: dir} do
    pid = start_store!(dir, @run_id, checkpoint_fun: fn _path, _record -> {:error, :rename_failed} end)

    assert {:error, {:membership_persistence_failed, {:checkpoint_failed, :rename_failed}}} =
             observe(pid, identity(), :queued)

    assert %{generation: 0, members: [], health: {:degraded, {:checkpoint_failed, :rename_failed}}} =
             Store.snapshot(server: pid)

    stop(pid)

    recovered = start_store!(dir)
    assert %{generation: 1, health: :healthy, members: [%{lifecycle: :queued}]} = Store.snapshot(server: recovered)
  end

  test "a checkpoint size refusal retains the journal instead of clearing recovery state", %{dir: dir} do
    pid = start_store!(dir, @run_id, checkpoint_fun: fn _path, _record -> {:error, :record_too_large} end)

    assert {:error, {:membership_persistence_failed, {:checkpoint_failed, :record_too_large}}} =
             observe(pid, identity(), :queued)

    assert File.read!(journal_path(dir)) != ""
    stop(pid)

    recovered = start_store!(dir)
    assert %{generation: 1, health: :healthy, members: [%{lifecycle: :queued}]} = Store.snapshot(server: recovered)
  end

  test "every checkpoint replacement is synced before its journal can be cleared", %{dir: dir} do
    {:ok, sync_count} = Agent.start_link(fn -> 0 end)

    sync_fun = fn ->
      case Agent.get_and_update(sync_count, fn count -> {count, count + 1} end) do
        0 -> :ok
        _ -> {:error, :sync_failed}
      end
    end

    pid = start_store!(dir, @run_id, filesystem_sync_fun: sync_fun)

    assert {:error, {:membership_persistence_failed, {:checkpoint_entry_sync_failed, :sync_failed}}} =
             observe(pid, identity(), :queued)

    assert %{generation: 0, members: [], health: {:degraded, {:checkpoint_entry_sync_failed, :sync_failed}}} =
             Store.snapshot(server: pid)

    stop(pid)
    recovered = start_store!(dir)
    assert %{generation: 1, health: :healthy, members: [%{lifecycle: :queued}]} = Store.snapshot(server: recovered)
  end

  test "a checkpoint replacement sync failure retains the journal for recovery", %{dir: dir} do
    first = start_store!(dir)
    assert {:ok, %{generation: 1}} = observe(first, identity(), :queued)
    stop(first)

    second =
      start_store!(dir, @run_id, filesystem_sync_fun: fn -> {:error, :sync_failed} end)

    assert {:error, {:membership_persistence_failed, {:checkpoint_entry_sync_failed, :sync_failed}}} =
             observe(second, identity(), :running, 1)

    stop(second)
    recovered = start_store!(dir)

    assert %{generation: 2, health: :healthy, members: [%{lifecycle: :running}]} =
             Store.snapshot(server: recovered)
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

  test "a crash between an fsynced append and checkpoint replay recovers the member", %{dir: dir} do
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
    assert_receive :checkpoint_started, @async_assert_timeout
    task_ref = Process.monitor(task)
    crash(pid)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}, @async_assert_timeout

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
    defaults = [name: nil, state_dir: dir, run_id: run_id, checkpoint_interval: 1]
    {:ok, pid} = Store.start_link(Keyword.merge(defaults, opts))
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

  defp checkpoint_checksum(record) do
    {record["version"], record["run_id"], record["generation"], record["members"]}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp only_path(dir, filename) do
    [path] = Path.wildcard(Path.join([dir, "runs", "*", filename]))
    path
  end

  defp stop(pid), do: Aiur.TestSupport.safe_stop(pid)

  defp crash(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, @async_assert_timeout
  end
end

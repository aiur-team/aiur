defmodule Aiur.UsageLedger.RecoveryTest do
  use ExUnit.Case, async: false

  alias Aiur.DecisionLog
  alias Aiur.UsageLedger.{Checkpoint, CounterPolicy, Paths, Record, Recovery}
  import Aiur.TestSupport.UsageLedger, only: [envelope: 1]

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-usage-ledger-recovery")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, persistence: Recovery.options(filesystem_sync_fun: fn -> :ok end)}
  end

  test "rebuilds missing checkpoints from canonical records without changing pinned evidence", %{root: root, persistence: persistence} do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    record = canonical_record(1)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(record))

    assert {:ok, state} = Recovery.boot(root, persistence)
    assert state.health == :healthy
    assert state.writable?
    assert state.position == 1
    assert state.policy.idempotency == MapSet.new([CounterPolicy.idempotency_key(record.envelope)])
    assert {:ok, rebuilt_checkpoint} = Checkpoint.load(paths.checkpoint_path)
    assert rebuilt_checkpoint.position == 1
    assert rebuilt_checkpoint.generation == 1
    assert [replayed] = state.records
    assert replayed.envelope.source_version == "2026-07"
    assert replayed.delta.relationship_revision == "codex-app-server-2026-07"
  end

  test "quarantines a torn tail while retaining the validated prefix", %{root: root, persistence: persistence} do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    record = canonical_record(1)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(record))
    :ok = File.write(paths.segment_path, "{\"partial\"", [:append])

    assert {:ok, state} = Recovery.boot(root, persistence)
    assert state.health == {:degraded, :segment_torn}
    refute state.writable?
    assert [%{position: 1}] = state.records
    assert String.ends_with?(File.read!(paths.segment_path), "\n")
    assert {:ok, [_entry]} = File.ls(paths.quarantine_dir)

    assert {:ok, restarted} = Recovery.boot(root, persistence)
    assert restarted.health == {:degraded, :segment_torn}
    refute restarted.writable?
  end

  test "quarantines malformed complete segments and reports degraded health without resetting the prefix", %{root: root, persistence: persistence} do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    record = canonical_record(1)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(record))
    :ok = File.write(paths.segment_path, "{\"forged\":true}\n", [:append])

    assert {:ok, state} = Recovery.boot(root, persistence)
    assert state.health == {:degraded, :segment_corrupt}
    refute state.writable?
    assert [%{position: 1}] = state.records
    assert {:ok, [%{position: 1}], nil} = DecisionLog.replay(paths.segment_path, &Record.decode/1)
    assert {:ok, [_entry]} = File.ls(paths.quarantine_dir)

    assert {:ok, restarted} = Recovery.boot(root, persistence)
    assert restarted.health == {:degraded, :segment_corrupt}
    refute restarted.writable?
    assert [%{position: 1}] = restarted.records
  end

  test "quarantines a bad checkpoint but safely rebuilds its canonical prefix", %{root: root, persistence: persistence} do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    record = canonical_record(1)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(record))
    :ok = File.write(paths.checkpoint_path, "{\"version\":99}")

    assert {:ok, state} = Recovery.boot(root, persistence)
    assert state.health == {:degraded, :checkpoint_corrupt}
    refute state.writable?
    assert [%{position: 1}] = state.records
    assert {:ok, [_entry]} = File.ls(paths.quarantine_dir)
  end

  test "fails closed on a forged suffix while retaining the checkpointed canonical prefix", %{
    root: root,
    persistence: persistence
  } do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    first_envelope = envelope(%{})
    {:ok, %{state: first_policy, delta: first_delta}} = CounterPolicy.apply(CounterPolicy.new(), first_envelope)
    {:ok, first_record} = Record.new(1, first_envelope, first_delta)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(first_record))

    checkpoint = Checkpoint.record(1, 1, first_policy)
    :ok = Checkpoint.write(paths.checkpoint_path, checkpoint)

    second_envelope = envelope(%{idempotency_key: "codex:evt-18", source_event_id: "evt-18", source_sequence: 18})
    {:ok, %{delta: second_delta}} = CounterPolicy.apply(first_policy, second_envelope)
    {:ok, second_record} = Record.new(2, second_envelope, second_delta)

    forged =
      second_record
      |> Record.encode()
      |> put_in(["delta", "tokens", "input"], 9)
      |> Jason.encode!()
      |> then(&(&1 <> "\n"))

    :ok = File.write(paths.segment_path, forged, [:append])

    assert {:ok, state} = Recovery.boot(root, persistence)
    assert state.health == {:degraded, :segment_corrupt}
    refute state.writable?
    assert state.position == 1
    assert state.generation == 1
    assert [%{position: 1}] = state.records
    assert CounterPolicy.dump(state.policy) == CounterPolicy.dump(first_policy)
    assert {:ok, [%{position: 1}], nil} = DecisionLog.replay(paths.segment_path, &Record.decode/1)
    assert {:ok, [_entry]} = File.ls(paths.quarantine_dir)

    assert {:ok, restarted} = Recovery.boot(root, persistence)
    assert restarted.health == {:degraded, :segment_corrupt}
    assert restarted.position == 1
    assert [%{position: 1}] = restarted.records
  end

  test "retains and repairs the valid prefix when canonical positions skip or repeat", %{
    root: root,
    persistence: persistence
  } do
    Enum.each([3, 1], fn invalid_position ->
      case_root = Path.join(root, "position-#{invalid_position}")
      {:ok, paths} = Paths.prepare(case_root, persistence.sync_fun)
      {first, second, _first_policy} = two_records()
      :ok = DecisionLog.append(paths.segment_path, Record.encode(first))
      :ok = DecisionLog.append(paths.segment_path, Record.encode(%{second | position: invalid_position}))

      assert {:ok, state} = Recovery.boot(case_root, persistence)
      assert state.health == {:degraded, :segment_corrupt}
      refute state.writable?
      assert state.position == 1
      assert [%{position: 1}] = state.records
      assert {:ok, [%{position: 1}], nil} = DecisionLog.replay(paths.segment_path, &Record.decode/1)
    end)
  end

  test "an invalid marker does not hide an otherwise valid raw prefix", %{
    root: root,
    persistence: persistence
  } do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    record = canonical_record(1)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(record))
    original_segment = File.read!(paths.segment_path)
    :ok = File.write(paths.degraded_path, "not-a-marker")

    assert {:ok, state} = Recovery.boot(root, persistence)
    assert state.health == {:unavailable, :marker_invalid}
    refute state.writable?
    assert state.position == 1
    assert [%{position: 1}] = state.records
    assert File.read!(paths.segment_path) == original_segment
    refute File.exists?(paths.checkpoint_path)
  end

  test "persists the marker before checkpoint, complete-segment, and torn-tail repair", %{
    root: root,
    persistence: persistence
  } do
    checkpoint_root = Path.join(root, "checkpoint")
    {:ok, checkpoint_paths} = Paths.prepare(checkpoint_root, persistence.sync_fun)
    :ok = DecisionLog.append(checkpoint_paths.segment_path, Record.encode(canonical_record(1)))
    :ok = File.write(checkpoint_paths.checkpoint_path, "{\"version\":99}")
    checkpoint_persistence = instrument_recovery(persistence, self())

    assert {:ok, %{health: {:degraded, :checkpoint_corrupt}}} =
             Recovery.boot(checkpoint_root, checkpoint_persistence)

    assert recovery_stages(3) == [
             :marker,
             {:quarantine, "checkpoint.json"},
             :checkpoint_rewrite
           ]

    segment_root = Path.join(root, "segment")
    {:ok, segment_paths} = Paths.prepare(segment_root, persistence.sync_fun)
    :ok = DecisionLog.append(segment_paths.segment_path, Record.encode(canonical_record(1)))
    :ok = File.write(segment_paths.segment_path, "{\"forged\":true}\n", [:append])
    segment_persistence = instrument_recovery(persistence, self())

    assert {:ok, %{health: {:degraded, :segment_corrupt}}} =
             Recovery.boot(segment_root, segment_persistence)

    assert recovery_stages(4) == [
             :marker,
             {:quarantine, "00000001.ndjson"},
             :segment_rewrite,
             :checkpoint_rewrite
           ]

    torn_root = Path.join(root, "torn")
    {:ok, torn_paths} = Paths.prepare(torn_root, persistence.sync_fun)
    :ok = DecisionLog.append(torn_paths.segment_path, Record.encode(canonical_record(1)))
    :ok = File.write(torn_paths.segment_path, "{\"partial\"", [:append])
    torn_persistence = instrument_recovery(persistence, self())

    assert {:ok, %{health: {:degraded, :segment_torn}}} = Recovery.boot(torn_root, torn_persistence)

    assert recovery_stages(4) == [
             :marker,
             {:quarantine, "00000001.ndjson"},
             :segment_rewrite,
             :checkpoint_rewrite
           ]
  end

  test "fails safely at marker, quarantine, and rewrite boundaries and resumes from the marker", %{
    root: root,
    persistence: persistence
  } do
    Enum.each([:marker, :quarantine, :rewrite, :checkpoint_rewrite], fn failed_stage ->
      case_root = Path.join(root, Atom.to_string(failed_stage))
      {:ok, paths} = Paths.prepare(case_root, persistence.sync_fun)
      :ok = DecisionLog.append(paths.segment_path, Record.encode(canonical_record(1)))
      :ok = File.write(paths.segment_path, "{\"forged\":true}\n", [:append])
      original_segment = File.read!(paths.segment_path)
      faulted = faulted_recovery(persistence, failed_stage)

      assert {:ok, state} = Recovery.boot(case_root, faulted)
      assert state.health == fault_health(failed_stage)
      refute state.writable?
      assert state.position == 1

      if failed_stage == :checkpoint_rewrite do
        assert {:ok, [%{position: 1}], nil} =
                 DecisionLog.replay(paths.segment_path, &Record.decode/1)
      else
        assert File.read!(paths.segment_path) == original_segment
      end

      if failed_stage == :marker do
        refute File.exists?(paths.degraded_path)
        refute File.exists?(paths.quarantine_dir)
      else
        assert File.exists?(paths.degraded_path)
      end

      assert {:ok, repaired} = Recovery.boot(case_root, persistence)
      assert repaired.health == {:degraded, :segment_corrupt}
      assert repaired.position == 1
      assert {:ok, [%{position: 1}], nil} = DecisionLog.replay(paths.segment_path, &Record.decode/1)
    end)
  end

  test "filesystem-syncs the degraded marker before quarantine starts", %{
    root: root,
    persistence: persistence
  } do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(canonical_record(1)))
    :ok = File.write(paths.segment_path, "{\"forged\":true}\n", [:append])
    parent = self()
    marker_fun = persistence.degraded_marker_fun
    quarantine_fun = persistence.quarantine_fun

    instrumented = %{
      persistence
      | sync_fun: fn ->
          send(parent, :recovery_filesystem_synced)
          :ok
        end,
        degraded_marker_fun: fn path, reason, sync_fun ->
          send(parent, :degraded_marker_started)
          marker_fun.(path, reason, sync_fun)
        end,
        quarantine_fun: fn path, quarantine_dir, sync_fun ->
          send(parent, :quarantine_started)
          quarantine_fun.(path, quarantine_dir, sync_fun)
        end
    }

    assert {:ok, %{health: {:degraded, :segment_corrupt}}} = Recovery.boot(root, instrumented)
    assert_receive :degraded_marker_started, 2_000
    assert_receive :recovery_filesystem_synced, 2_000
    assert_receive :quarantine_started, 2_000
  end

  test "recovers when a completed repair stage reports failure after its durable effect", %{
    root: root,
    persistence: persistence
  } do
    Enum.each([:marker, :quarantine, :rewrite, :checkpoint_rewrite], fn failed_stage ->
      case_root = Path.join(root, "after-#{failed_stage}")
      {:ok, paths} = Paths.prepare(case_root, persistence.sync_fun)
      :ok = DecisionLog.append(paths.segment_path, Record.encode(canonical_record(1)))
      :ok = File.write(paths.segment_path, "{\"forged\":true}\n", [:append])

      assert {:ok, failed} = Recovery.boot(case_root, fault_after_recovery(persistence, failed_stage))
      assert failed.health == fault_health(failed_stage)
      assert failed.position == 1
      refute failed.writable?
      assert File.exists?(paths.degraded_path)

      assert {:ok, repaired} = Recovery.boot(case_root, persistence)
      assert repaired.health == {:degraded, :segment_corrupt}
      assert repaired.position == 1
      assert [%{position: 1}] = repaired.records
      assert {:ok, [%{position: 1}], nil} = DecisionLog.replay(paths.segment_path, &Record.decode/1)
    end)
  end

  test "reuses quarantine evidence across repeated failed recovery restarts", %{
    root: root,
    persistence: persistence
  } do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(canonical_record(1)))
    :ok = File.write(paths.segment_path, "{\"forged\":true}\n", [:append])
    :ok = File.write(paths.checkpoint_path, "{\"version\":99}")

    expected_bytes = File.stat!(paths.segment_path).size + File.stat!(paths.checkpoint_path).size

    expected_entries =
      [paths.segment_path, paths.checkpoint_path]
      |> Enum.map(&content_addressed_quarantine_entry/1)
      |> Enum.sort()

    faulted = fault_after_checkpoint_quarantine(persistence)

    snapshots =
      Enum.map(1..4, fn _restart ->
        assert {:ok, state} = Recovery.boot(root, faulted)
        assert state.health == {:unavailable, :quarantine_failed}
        assert state.position == 1
        quarantine_snapshot(paths.quarantine_dir)
      end)

    assert [%{entries: entries, total_bytes: ^expected_bytes} = snapshot] = Enum.uniq(snapshots)
    assert entries == expected_entries

    assert {:ok, %{health: {:degraded, :storage_corrupt}}} = Recovery.boot(root, persistence)
    assert quarantine_snapshot(paths.quarantine_dir) == snapshot
  end

  test "fails closed when existing content-addressed evidence does not match its digest", %{
    root: root,
    persistence: persistence
  } do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(canonical_record(1)))
    expected_entry = content_addressed_quarantine_entry(paths.segment_path)

    assert :ok = Paths.quarantine(paths.segment_path, paths.quarantine_dir, persistence.sync_fun)

    evidence_path = Path.join(paths.quarantine_dir, expected_entry)
    assert Bitwise.band(File.stat!(evidence_path).mode, 0o077) == 0
    :ok = File.write(evidence_path, "tampered")

    assert {:error, :quarantine_checksum_mismatch} =
             Paths.quarantine(paths.segment_path, paths.quarantine_dir, persistence.sync_fun)

    assert File.read!(evidence_path) == "tampered"
    assert File.ls!(paths.quarantine_dir) == [expected_entry]
  end

  test "rejects a symlink at the content-addressed quarantine destination", %{
    root: root,
    persistence: persistence
  } do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(canonical_record(1)))
    :ok = DecisionLog.ensure_directory(paths.quarantine_dir)

    external = Path.join(root, "external")
    :ok = File.write(external, "do not overwrite")

    destination =
      Path.join(paths.quarantine_dir, content_addressed_quarantine_entry(paths.segment_path))

    :ok = File.ln_s(external, destination)

    assert {:error, :symlink_rejected} =
             Paths.quarantine(paths.segment_path, paths.quarantine_dir, persistence.sync_fun)

    assert File.read!(external) == "do not overwrite"
  end

  test "quarantines a rechecksummed checkpoint with an impossible generation", %{root: root, persistence: persistence} do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    record = canonical_record(1)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(record))

    checkpoint = Checkpoint.record(1, 9, CounterPolicy.new())
    :ok = Checkpoint.write(paths.checkpoint_path, checkpoint)

    assert {:ok, state} = Recovery.boot(root, persistence)
    assert state.health == {:degraded, :checkpoint_corrupt}
    refute state.writable?
    assert state.generation == 1
  end

  defp canonical_record(position) do
    envelope = envelope(%{})
    {:ok, %{delta: delta}} = CounterPolicy.apply(CounterPolicy.new(), envelope)
    {:ok, record} = Record.new(position, envelope, delta)
    record
  end

  defp two_records do
    first_envelope = envelope(%{})
    {:ok, %{state: first_policy, delta: first_delta}} = CounterPolicy.apply(CounterPolicy.new(), first_envelope)
    {:ok, first_record} = Record.new(1, first_envelope, first_delta)

    second_envelope =
      envelope(%{
        idempotency_key: "codex:evt-18",
        source_event_id: "evt-18",
        source_sequence: 18
      })

    {:ok, %{delta: second_delta}} = CounterPolicy.apply(first_policy, second_envelope)
    {:ok, second_record} = Record.new(2, second_envelope, second_delta)
    {first_record, second_record, first_policy}
  end

  defp instrument_recovery(persistence, recipient) do
    marker_fun = persistence.degraded_marker_fun
    quarantine_fun = persistence.quarantine_fun
    rewrite_fun = persistence.rewrite_segment_fun
    checkpoint_fun = persistence.checkpoint_write_fun

    %{
      persistence
      | degraded_marker_fun: fn path, reason, sync_fun ->
          send(recipient, {:recovery_stage, :marker})
          marker_fun.(path, reason, sync_fun)
        end,
        quarantine_fun: fn path, quarantine_dir, sync_fun ->
          send(recipient, {:recovery_stage, {:quarantine, Path.basename(path)}})
          quarantine_fun.(path, quarantine_dir, sync_fun)
        end,
        rewrite_segment_fun: fn path, records, sync_fun ->
          send(recipient, {:recovery_stage, :segment_rewrite})
          rewrite_fun.(path, records, sync_fun)
        end,
        checkpoint_write_fun: fn path, checkpoint, max_bytes ->
          send(recipient, {:recovery_stage, :checkpoint_rewrite})
          checkpoint_fun.(path, checkpoint, max_bytes)
        end
    }
  end

  defp recovery_stages(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:recovery_stage, stage}, 2_000
      stage
    end)
  end

  defp faulted_recovery(persistence, :marker) do
    %{persistence | degraded_marker_fun: fn _path, _reason, _sync_fun -> {:error, :injected_marker_failure} end}
  end

  defp faulted_recovery(persistence, :quarantine) do
    %{persistence | quarantine_fun: fn _path, _quarantine_dir, _sync_fun -> {:error, :injected_quarantine_failure} end}
  end

  defp faulted_recovery(persistence, :rewrite) do
    %{persistence | rewrite_segment_fun: fn _path, _records, _sync_fun -> {:error, :injected_rewrite_failure} end}
  end

  defp faulted_recovery(persistence, :checkpoint_rewrite) do
    %{
      persistence
      | checkpoint_write_fun: fn _path, _checkpoint, _max_bytes ->
          {:error, :injected_checkpoint_failure}
        end
    }
  end

  defp fault_after_recovery(persistence, :marker) do
    marker_fun = persistence.degraded_marker_fun

    %{
      persistence
      | degraded_marker_fun: fn path, reason, sync_fun ->
          :ok = marker_fun.(path, reason, sync_fun)
          {:error, :injected_marker_failure}
        end
    }
  end

  defp fault_after_recovery(persistence, :quarantine) do
    quarantine_fun = persistence.quarantine_fun

    %{
      persistence
      | quarantine_fun: fn path, quarantine_dir, sync_fun ->
          :ok = quarantine_fun.(path, quarantine_dir, sync_fun)
          {:error, :injected_quarantine_failure}
        end
    }
  end

  defp fault_after_recovery(persistence, :rewrite) do
    rewrite_fun = persistence.rewrite_segment_fun

    %{
      persistence
      | rewrite_segment_fun: fn path, records, sync_fun ->
          :ok = rewrite_fun.(path, records, sync_fun)
          {:error, :injected_rewrite_failure}
        end
    }
  end

  defp fault_after_recovery(persistence, :checkpoint_rewrite) do
    checkpoint_fun = persistence.checkpoint_write_fun

    %{
      persistence
      | checkpoint_write_fun: fn path, checkpoint, max_bytes ->
          :ok = checkpoint_fun.(path, checkpoint, max_bytes)
          {:error, :injected_checkpoint_failure}
        end
    }
  end

  defp fault_after_checkpoint_quarantine(persistence) do
    quarantine_fun = persistence.quarantine_fun

    %{
      persistence
      | quarantine_fun: fn path, quarantine_dir, sync_fun ->
          with :ok <- quarantine_fun.(path, quarantine_dir, sync_fun) do
            if Path.basename(path) == "checkpoint.json",
              do: {:error, :injected_checkpoint_quarantine_failure},
              else: :ok
          end
        end
    }
  end

  defp quarantine_snapshot(quarantine_dir) do
    entries = quarantine_dir |> File.ls!() |> Enum.sort()

    total_bytes =
      Enum.reduce(entries, 0, fn entry, total ->
        total + File.stat!(Path.join(quarantine_dir, entry)).size
      end)

    %{entries: entries, total_bytes: total_bytes}
  end

  defp content_addressed_quarantine_entry(path) do
    digest = path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    "#{Path.basename(path)}.sha256-#{digest}.quarantine"
  end

  defp fault_health(:marker), do: {:unavailable, :degraded_marker_failed}
  defp fault_health(:quarantine), do: {:unavailable, :quarantine_failed}
  defp fault_health(:rewrite), do: {:unavailable, :repair_failed}
  defp fault_health(:checkpoint_rewrite), do: {:unavailable, :repair_failed}
end

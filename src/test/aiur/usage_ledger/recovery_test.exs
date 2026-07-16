defmodule Aiur.UsageLedger.RecoveryTest do
  use ExUnit.Case, async: false

  alias Aiur.DecisionLog
  alias Aiur.UsageLedger.{CounterPolicy, Paths, Record, Recovery}
  import Aiur.TestSupport.UsageLedger, only: [envelope: 1]

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-usage-ledger-recovery-#{System.unique_integer([:positive])}")
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

  test "fails closed when a checkpointed canonical delta is forged", %{root: root, persistence: persistence} do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    record = canonical_record(1)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(record))

    checkpoint = Aiur.UsageLedger.Checkpoint.record(1, 1, CounterPolicy.new())
    :ok = Aiur.UsageLedger.Checkpoint.write(paths.checkpoint_path, checkpoint)

    forged = record |> Record.encode() |> put_in(["delta", "tokens", "input"], 9) |> Jason.encode!() |> then(&(&1 <> "\n"))
    :ok = File.write(paths.segment_path, forged)

    assert {:ok, state} = Recovery.boot(root, persistence)
    assert state.health == {:unavailable, :record_delta_mismatch}
    refute state.writable?
  end

  test "quarantines a rechecksummed checkpoint with an impossible generation", %{root: root, persistence: persistence} do
    {:ok, paths} = Paths.prepare(root, persistence.sync_fun)
    record = canonical_record(1)
    :ok = DecisionLog.append(paths.segment_path, Record.encode(record))

    checkpoint = Aiur.UsageLedger.Checkpoint.record(1, 9, CounterPolicy.new())
    :ok = Aiur.UsageLedger.Checkpoint.write(paths.checkpoint_path, checkpoint)

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
end

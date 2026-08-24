defmodule Aiur.UsageLedger.CheckpointTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Aiur.UsageLedger.{Checkpoint, CounterPolicy}
  import Aiur.TestSupport.UsageLedger, only: [envelope: 1]

  test "round-trips a checksummed counter and idempotency checkpoint" do
    checkpoint = Checkpoint.record(4, 9, CounterPolicy.new())

    assert {:ok, restored} = checkpoint |> Jason.encode!() |> Jason.decode!() |> Checkpoint.from_record()
    assert restored.position == 4
    assert restored.generation == 9
    assert restored.policy.idempotency == MapSet.new()
  end

  test "rejects an altered checksum and refuses an oversized checkpoint" do
    checkpoint = Checkpoint.record(0, 0, CounterPolicy.new())
    assert {:error, :checksum_mismatch} = Checkpoint.from_record(Map.put(checkpoint, "generation", 1))

    path = Aiur.TestSupport.tmp_root!("aiur-usage-ledger-checkpoint")
    assert {:error, :record_too_large} = Checkpoint.write(path, checkpoint, max_bytes: 1)
    refute File.exists?(path)
  end

  test "rejects rechecksummed checkpoint policy fields outside the canonical schema" do
    {:ok, %{state: policy}} = CounterPolicy.apply(CounterPolicy.new(), envelope(%{}))
    dumped = CounterPolicy.dump(policy)
    [counter_key | _rest] = Map.keys(dumped["absolute"])

    assert {:error, :invalid_ledger_checkpoint} =
             CounterPolicy.load(put_in(dumped, ["absolute", counter_key, "credential"], "ghp_0123456789abcdef"))
  end

  test "rejects checksummed position and policy integers outside the ledger bound" do
    huge_integer = 1 <<< 100_000
    oversized_position = Checkpoint.record(huge_integer, huge_integer, CounterPolicy.new())
    assert {:error, :invalid_ledger_checkpoint} = Checkpoint.from_record(oversized_position)

    oversized_generation = Checkpoint.record(0, huge_integer, CounterPolicy.new())
    assert {:error, :invalid_ledger_checkpoint} = Checkpoint.from_record(oversized_generation)

    {:ok, %{state: policy}} = CounterPolicy.apply(CounterPolicy.new(), envelope(%{}))
    dumped = CounterPolicy.dump(policy)
    [counter_key | _rest] = Map.keys(dumped["absolute"])

    assert {:error, :invalid_ledger_checkpoint} =
             CounterPolicy.load(put_in(dumped, ["absolute", counter_key, "value"], huge_integer))

    assert {:error, :invalid_ledger_checkpoint} =
             CounterPolicy.load(put_in(dumped, ["absolute", counter_key, "source_sequence"], huge_integer))

    assert {:error, :invalid_ledger_checkpoint} =
             CounterPolicy.load(put_in(dumped, ["coverage", "upper"], huge_integer))
  end

  test "durably overwrites a prepared checkpoint without replacing its path" do
    path = Aiur.TestSupport.tmp_root!("aiur-usage-ledger-checkpoint")
    on_exit(fn -> File.rm(path) end)

    first = Checkpoint.record(0, 0, CounterPolicy.new())
    second = Checkpoint.record(4, 9, CounterPolicy.new())

    assert :ok = Checkpoint.write(path, first)
    assert {:ok, before} = File.stat(path)
    assert :ok = Checkpoint.overwrite_encoded(path, Jason.encode!(second))
    assert {:ok, after_overwrite} = File.stat(path)
    assert before.inode == after_overwrite.inode
    assert {:ok, %{position: 4, generation: 9}} = Checkpoint.load(path)
  end

  test "targeted checkpoint overwrite requires a prepared regular file" do
    path = Aiur.TestSupport.tmp_root!("aiur-usage-ledger-checkpoint")

    assert {:error, :missing_checkpoint} = Checkpoint.overwrite_encoded(path, "{}")
  end
end

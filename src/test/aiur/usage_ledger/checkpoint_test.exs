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

    path = Path.join(System.tmp_dir!(), "aiur-usage-ledger-checkpoint-#{System.unique_integer([:positive])}")
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
end

defmodule Aiur.UsageLedger.RetirementTest do
  use ExUnit.Case, async: false

  alias Aiur.UsageLedger.{Checkpoint, RetiredFloor, RetiredKeys, Store}

  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1]

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-retire")
    File.mkdir_p!(root)
    name = :"ledger_#{System.unique_integer([:positive])}"
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root, name: name}
  end

  defp start_ledger(root, name, opts \\ []) do
    Store.start_link(Keyword.merge([name: name, state_dir: root, filesystem_sync_fun: fn -> :ok end], opts))
  end

  defp append_n(name, count) do
    for _ <- 1..count, do: {:ok, _} = GenServer.call(name, {:append, envelope(%{tokens: %{input: 10}})})
  end

  defp scan_positions(name) do
    {:ok, records} = GenServer.call(name, {:scan, [after: 0]})
    Enum.map(records, & &1.position)
  end

  test "retires the raw prefix while preserving head, coverage, and totals", context do
    {:ok, ledger} = start_ledger(context.root, context.name)
    append_n(context.name, 5)
    coverage_before = GenServer.call(context.name, :coverage)

    assert {:ok, %{retired_through: 2, retired_count: 2}} = Store.retire(context.name, 2)

    assert scan_positions(context.name) == [3, 4, 5]
    assert GenServer.call(context.name, :generation) == 5
    assert GenServer.call(context.name, :coverage) == coverage_before
    assert File.exists?(Path.join(context.root, "retired.json"))
    GenServer.stop(ledger)
  end

  test "retirement is idempotent and never crosses the head", context do
    {:ok, ledger} = start_ledger(context.root, context.name)
    append_n(context.name, 3)

    assert {:ok, %{retired_through: 2}} = Store.retire(context.name, 2)
    assert {:ok, %{retired_through: 2, retired_count: 0}} = Store.retire(context.name, 1)
    assert {:ok, %{retired_through: 2, retired_count: 0}} = Store.retire(context.name, 2)
    assert {:error, :watermark_beyond_head} = Store.retire(context.name, 99)

    assert scan_positions(context.name) == [3]
    GenServer.stop(ledger)
  end

  test "recovers a retired ledger from the trusted checkpoint and retained tail", context do
    {:ok, ledger} = start_ledger(context.root, context.name)
    append_n(context.name, 5)
    {:ok, _} = Store.retire(context.name, 3)
    GenServer.stop(ledger)

    {:ok, restarted} = start_ledger(context.root, context.name)
    assert scan_positions(context.name) == [4, 5]
    assert GenServer.call(context.name, :generation) == 5
    assert GenServer.call(context.name, :health) == :healthy
    GenServer.stop(restarted)
  end

  test "replays appends after the retired checkpoint on recovery", context do
    {:ok, ledger} = start_ledger(context.root, context.name)
    append_n(context.name, 5)
    {:ok, _} = Store.retire(context.name, 3)
    append_n(context.name, 2)
    GenServer.stop(ledger)

    {:ok, restarted} = start_ledger(context.root, context.name)
    assert scan_positions(context.name) == [4, 5, 6, 7]
    assert GenServer.call(context.name, :generation) == 7
    assert GenServer.call(context.name, :health) == :healthy
    GenServer.stop(restarted)
  end

  test "retirement stores large idempotency history outside the checkpoint cap", context do
    {:ok, ledger} = start_ledger(context.root, context.name)
    first = envelope(%{})
    {:ok, _} = GenServer.call(context.name, {:append, first})

    for index <- 1..2_400 do
      key = "codex:" <> String.duplicate("k", 240) <> "-#{index}"
      {:ok, _} = GenServer.call(context.name, {:append, envelope(%{idempotency_key: key})})
    end

    assert {:ok, %{retired_through: 2_401}} = Store.retire(context.name, 2_401)
    assert File.stat!(Path.join(context.root, "checkpoint.json")).size < 1_048_576
    GenServer.stop(ledger)

    {:ok, restarted} = start_ledger(context.root, context.name)
    assert GenServer.call(context.name, :health) == :healthy
    assert GenServer.call(context.name, :generation) == 2_401
    assert {:duplicate, _ack} = GenServer.call(context.name, {:append, first})
    GenServer.stop(restarted)
  end

  # The checkpoint cap bounds the retained counter state. After a retirement the
  # full idempotency history lives in retired-idempotency.json, so a checkpoint
  # that also carried every key overflowed the cap, rejected the append, and
  # left the checkpoint due again on every later append (2026-11 wedge).
  @wedge_opts [checkpoint_interval: 10, limits: [max_checkpoint_bytes: 200_000]]

  test "appends keep landing at the checkpoint interval after retiring a large key history", context do
    {:ok, ledger} = start_ledger(context.root, context.name, @wedge_opts)
    append_long_keys(context.name, 1..600)
    {:ok, _} = Store.retire(context.name, 600)

    for index <- 601..625 do
      assert {:ok, %{position: ^index}} = GenServer.call(context.name, {:append, long_key_envelope(index)})
    end

    assert GenServer.call(context.name, :health) == :healthy
    assert {:ok, %{position: 620}} = Checkpoint.load(Path.join(context.root, "checkpoint.json"), max_bytes: 200_000)
    GenServer.stop(ledger)

    {:ok, restarted} = start_ledger(context.root, context.name, @wedge_opts)
    assert GenServer.call(context.name, :generation) == 625
    assert {:duplicate, _ack} = GenServer.call(context.name, {:append, long_key_envelope(1)})
    GenServer.stop(restarted)
  end

  test "a ledger left wedged on disk boots and appends without losing records", context do
    {:ok, ledger} = start_ledger(context.root, context.name, @wedge_opts)
    append_long_keys(context.name, 1..600)
    {:ok, _} = Store.retire(context.name, 600)
    append_long_keys(context.name, 601..609)

    # The wedged shape: the last good checkpoint sits one interval behind the
    # segment head, and a failed retirement already archived every key up to it.
    %{policy: policy} = :sys.get_state(context.name)
    :ok = RetiredKeys.write(Path.join(context.root, "retired-idempotency.json"), 609, policy.idempotency)
    GenServer.stop(ledger)

    {:ok, restarted} = start_ledger(context.root, context.name, @wedge_opts)
    assert GenServer.call(context.name, :health) == :healthy
    assert GenServer.call(context.name, :generation) == 609
    assert {:ok, %{position: 610}} = GenServer.call(context.name, {:append, long_key_envelope(610)})
    assert {:ok, %{position: 610}} = Checkpoint.load(Path.join(context.root, "checkpoint.json"), max_bytes: 200_000)
    GenServer.stop(restarted)

    {:ok, recovered} = start_ledger(context.root, context.name, @wedge_opts)
    assert GenServer.call(context.name, :health) == :healthy
    assert GenServer.call(context.name, :generation) == 610
    assert scan_positions(context.name) == Enum.to_list(601..610)
    assert {:duplicate, _ack} = GenServer.call(context.name, {:append, long_key_envelope(1)})
    assert {:duplicate, _ack} = GenServer.call(context.name, {:append, long_key_envelope(605)})
    GenServer.stop(recovered)
  end

  defp append_long_keys(name, range) do
    for index <- range, do: {:ok, _} = GenServer.call(name, {:append, long_key_envelope(index)})
  end

  defp long_key_envelope(index), do: envelope(%{idempotency_key: "codex:" <> String.duplicate("k", 240) <> "-#{index}"})

  test "recovery excludes archived keys newer than a failed checkpoint", context do
    {:ok, ledger} = start_ledger(context.root, context.name, checkpoint_interval: 2)
    append_n(context.name, 4)
    {:ok, _} = Store.retire(context.name, 2)
    GenServer.stop(ledger)

    fail_checkpoint = fn _path, _encoded -> {:error, :eio} end

    {:ok, restarted_with_failure} =
      start_ledger(context.root, context.name, checkpoint_interval: 2, checkpoint_fun: fail_checkpoint)

    assert {:ok, _} = GenServer.call(context.name, {:append, envelope(%{})})
    assert {:error, :persistence_failed} = GenServer.call(context.name, {:append, envelope(%{})})
    GenServer.stop(restarted_with_failure)

    {:ok, recovered} = start_ledger(context.root, context.name)
    assert GenServer.call(context.name, :health) == :healthy
    assert GenServer.call(context.name, :generation) == 6
    GenServer.stop(recovered)
  end

  test "a floor persisted before the segment is reclaimed still drops the retired prefix on boot", context do
    {:ok, ledger} = start_ledger(context.root, context.name, checkpoint_interval: 1)
    append_n(context.name, 5)
    GenServer.stop(ledger)

    # Simulate a crash after the floor was fsynced but before the segment was
    # rewritten: the full segment is still on disk, only the floor is present.
    :ok = RetiredFloor.write(Path.join(context.root, "retired.json"), 2, fn -> :ok end)

    {:ok, restarted} = start_ledger(context.root, context.name)
    assert scan_positions(context.name) == [3, 4, 5]
    assert GenServer.call(context.name, :health) == :healthy
    GenServer.stop(restarted)
  end

  test "halts safely when the checkpoint is missing after retirement", context do
    {:ok, ledger} = start_ledger(context.root, context.name)
    append_n(context.name, 4)
    {:ok, _} = Store.retire(context.name, 2)
    GenServer.stop(ledger)

    File.rm!(Path.join(context.root, "checkpoint.json"))
    {:ok, restarted} = start_ledger(context.root, context.name)

    assert {:unavailable, _reason} = GenServer.call(context.name, :health)
    assert {:error, :ledger_unavailable} = GenServer.call(context.name, {:append, envelope(%{})})
    GenServer.stop(restarted)
  end

  test "halts safely when the retired floor is corrupt", context do
    {:ok, ledger} = start_ledger(context.root, context.name)
    append_n(context.name, 4)
    {:ok, _} = Store.retire(context.name, 2)
    GenServer.stop(ledger)

    File.write!(Path.join(context.root, "retired.json"), "not json")
    {:ok, restarted} = start_ledger(context.root, context.name)

    assert {:unavailable, _reason} = GenServer.call(context.name, :health)
    GenServer.stop(restarted)
  end

  test "the retired floor artifact is content-free", context do
    {:ok, ledger} = start_ledger(context.root, context.name)
    append_n(context.name, 3)
    {:ok, _} = Store.retire(context.name, 2)
    GenServer.stop(ledger)

    contents = File.read!(Path.join(context.root, "retired.json"))
    assert {:ok, decoded} = Jason.decode(contents)
    assert Map.keys(decoded) |> Enum.sort() == ["checksum", "retired_through", "version"]
    assert decoded["retired_through"] == 2
  end
end

defmodule Aiur.UsageLedger.RetirementTest do
  use ExUnit.Case, async: false

  alias Aiur.UsageLedger.{RetiredFloor, Store}

  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1]

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-retire")
    File.mkdir_p!(root)
    name = :"ledger_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, name: name}
  end

  defp start_ledger(root, name) do
    Store.start_link(name: name, state_dir: root, filesystem_sync_fun: fn -> :ok end)
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

  test "a floor persisted before the segment is reclaimed still drops the retired prefix on boot", context do
    {:ok, ledger} = start_ledger(context.root, context.name)
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

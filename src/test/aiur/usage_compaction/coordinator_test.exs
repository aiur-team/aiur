defmodule Aiur.UsageCompaction.CoordinatorTest do
  use ExUnit.Case, async: false

  alias Aiur.UsageAggregate.Projection
  alias Aiur.UsageAggregate.Store, as: Aggregate
  alias Aiur.UsageCompaction.{Block, Coordinator, Floor, Manifest, Paths, Policy}
  alias Aiur.UsageLedger.Store, as: Ledger

  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1]

  setup do
    ledger_root = Path.join(System.tmp_dir!(), "aiur-cc-ledger-#{System.pid()}-#{System.unique_integer([:positive])}")
    comp_root = Path.join(System.tmp_dir!(), "aiur-cc-comp-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ledger_root)
    File.mkdir_p!(comp_root)
    ledger = :"cc_ledger_#{System.unique_integer([:positive])}"

    {:ok, _} = Ledger.start_link(name: ledger, state_dir: ledger_root, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      File.rm_rf(ledger_root)
      File.rm_rf(comp_root)
    end)

    %{ledger: ledger, ledger_root: ledger_root, comp_root: comp_root}
  end

  defp append_n(ledger, count) do
    for _ <- 1..count, do: {:ok, _} = GenServer.call(ledger, {:append, envelope(%{tokens: %{input: 10}})})
  end

  defp scan_all(ledger) do
    {:ok, records} = GenServer.call(ledger, {:scan, [after: 0]})
    records
  end

  defp ledger_opts(ledger) do
    [
      ledger_scan_fun: fn opts -> GenServer.call(ledger, {:scan, opts}) end,
      ledger_generation_fun: fn -> GenServer.call(ledger, :generation) end,
      ledger_retire_fun: fn watermark -> Ledger.retire(ledger, watermark) end
    ]
  end

  defp start_coordinator(context, policy) do
    opts =
      [
        name: :"cc_#{System.unique_integer([:positive])}",
        state_dir: context.comp_root,
        filesystem_sync_fun: fn -> :ok end,
        interval_ms: 0,
        policy: policy
      ] ++ ledger_opts(context.ledger)

    start_supervised!({Coordinator, opts})
  end

  defp small_policy, do: Policy.new(min_retained_positions: 3, max_retained_positions: 1, retire_batch: 1_000, max_retained_bytes: :infinity)

  test "commits durable coverage then retires the raw prefix in one cycle", context do
    append_n(context.ledger, 10)
    assert length(scan_all(context.ledger)) == 10

    coordinator = start_coordinator(context, small_policy())
    summary = Coordinator.compact(coordinator)

    assert summary.status == {:compacted, 1, 7}
    assert summary.retired_through == 7

    # Raw prefix is gone; the retained window survives.
    assert Enum.map(scan_all(context.ledger), & &1.position) == [8, 9, 10]

    # A finalized, gapless manifest and a durable block exist.
    {:ok, manifest} = Manifest.load(Paths.manifest_path(context.comp_root))
    assert manifest.retired_through == 7
    assert [%{first_position: 1, last_position: 7, ref: ref}] = Manifest.blocks(manifest)
    assert {:ok, _block} = Block.load(Paths.block_path(context.comp_root, ref))
  end

  test "the floor plus retained raw reproduces the full pre-compaction projection exactly", context do
    append_n(context.ledger, 10)
    full = Projection.apply_records(Projection.new(), scan_all(context.ledger))

    coordinator = start_coordinator(context, small_policy())
    assert Coordinator.compact(coordinator).status == {:compacted, 1, 7}

    {:ok, floor} = Floor.load(context.comp_root)
    seeded = Projection.seed(floor)
    reconstructed = Projection.apply_records(seeded, scan_all(context.ledger))

    assert reconstructed.cells == full.cells
    assert reconstructed.source_position == full.source_position
    assert floor.source_position == 7
  end

  test "is a noop when no range is eligible", context do
    append_n(context.ledger, 2)
    coordinator = start_coordinator(context, small_policy())

    assert Coordinator.compact(coordinator).status == :noop
    assert Enum.map(scan_all(context.ledger), & &1.position) == [1, 2]
  end

  test "reconciles a crash left at :prepared by rolling back, raw intact", context do
    append_n(context.ledger, 10)
    {:ok, paths} = Paths.prepare(context.comp_root, fn -> :ok end)

    # Simulate a crash right after declaring intent: manifest :prepared, a
    # half-written block present, raw untouched.
    {:ok, prepared} = Manifest.prepare(Manifest.new(), 1, 7, "block-x.json", 7)
    :ok = Manifest.write(paths.manifest_path, prepared)
    File.write!(Paths.block_path(context.comp_root, "block-x.json"), "partial")

    coordinator = start_coordinator(context, small_policy())
    snapshot = Coordinator.snapshot(coordinator)

    assert snapshot.retired_through == 0
    assert snapshot.health == :ok
    refute File.exists?(Paths.block_path(context.comp_root, "block-x.json"))
    assert length(scan_all(context.ledger)) == 10
  end

  test "reconciles a crash left at :source_retired by rolling forward", context do
    append_n(context.ledger, 10)
    {:ok, paths} = Paths.prepare(context.comp_root, fn -> :ok end)

    # Build a real block for [1,7] and stage the manifest at the point of no
    # return, before the raw was actually retired.
    {:ok, block} = Block.build(Enum.filter(scan_all(context.ledger), &(&1.position <= 7)))
    ref = Paths.block_ref(1, 7)
    :ok = Block.write(Paths.block_path(context.comp_root, ref), block)

    {:ok, m} = Manifest.prepare(Manifest.new(), 1, 7, ref, block.source_generation)
    {:ok, m} = Manifest.advance(m, :aggregate_committed)
    {:ok, m} = Manifest.advance(m, :source_retired)
    :ok = Manifest.write(paths.manifest_path, m)

    coordinator = start_coordinator(context, small_policy())
    snapshot = Coordinator.snapshot(coordinator)

    assert snapshot.retired_through == 7
    assert snapshot.health == :ok
    # Roll-forward retired the raw idempotently.
    assert Enum.map(scan_all(context.ledger), & &1.position) == [8, 9, 10]
  end

  test "the floor fails closed while a destructive phase is stuck at :source_retired", context do
    append_n(context.ledger, 10)
    {:ok, paths} = Paths.prepare(context.comp_root, fn -> :ok end)

    {:ok, block} = Block.build(Enum.filter(scan_all(context.ledger), &(&1.position <= 7)))
    ref = Paths.block_ref(1, 7)
    :ok = Block.write(Paths.block_path(context.comp_root, ref), block)

    {:ok, m} = Manifest.prepare(Manifest.new(), 1, 7, ref, block.source_generation)
    {:ok, m} = Manifest.advance(m, :aggregate_committed)
    {:ok, m} = Manifest.advance(m, :source_retired)
    :ok = Manifest.write(paths.manifest_path, m)

    # Raw for [1,7] may already be gone; rebuilding from finalized blocks alone
    # would undercount, so the floor must refuse rather than seed a short floor.
    assert Floor.load(context.comp_root) == {:error, :destructive_phase_in_flight}
  end

  test "an aggregate rebuild latches unavailable rather than undercount on a broken floor", context do
    append_n(context.ledger, 3)
    agg_root = Path.join(System.tmp_dir!(), "aiur-cc-agg-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(agg_root)
    on_exit(fn -> File.rm_rf(agg_root) end)
    agg = :"cc_agg_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Aggregate.start_link(
        name: agg,
        state_dir: agg_root,
        ledger_scan_fun: fn opts -> GenServer.call(context.ledger, {:scan, opts}) end,
        ledger_subscribe_fun: fn pid -> GenServer.call(context.ledger, {:subscribe, pid}) end,
        ledger_generation_fun: fn -> GenServer.call(context.ledger, :generation) end,
        ledger_coverage_fun: fn -> GenServer.call(context.ledger, :coverage) end,
        compaction_floor_fun: fn -> {:error, :destructive_phase_in_flight} end
      )

    assert {:unavailable, :compaction_floor_unavailable} = Aggregate.health(agg)
  end

  test "quarantines a corrupt manifest and halts destructive progress", context do
    append_n(context.ledger, 10)
    {:ok, paths} = Paths.prepare(context.comp_root, fn -> :ok end)
    File.write!(paths.manifest_path, "corrupt not json")

    coordinator = start_coordinator(context, small_policy())
    snapshot = Coordinator.snapshot(coordinator)

    assert match?({:quarantined, _reason}, snapshot.health)
    # Destructive work is halted; raw untouched.
    assert length(scan_all(context.ledger)) == 10
    assert Coordinator.compact(coordinator).retired_through == 0
    assert File.ls!(paths.quarantine_dir) != []
  end

  test "produces content-free block and manifest artifacts", context do
    append_n(context.ledger, 10)
    coordinator = start_coordinator(context, small_policy())
    assert Coordinator.compact(coordinator).status == {:compacted, 1, 7}

    manifest_bytes = File.read!(Paths.manifest_path(context.comp_root))
    [block_file] = File.ls!(paths_blocks(context.comp_root))
    block_bytes = File.read!(Path.join(paths_blocks(context.comp_root), block_file))

    for bytes <- [manifest_bytes, block_bytes], secret <- ["prompt", "authorization", "sk-", "secret", "password"] do
      refute String.contains?(String.downcase(bytes), secret)
    end
  end

  defp paths_blocks(root), do: Path.join(root, "blocks")
end

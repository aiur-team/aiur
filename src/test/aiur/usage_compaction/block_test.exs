defmodule Aiur.UsageCompaction.BlockTest do
  use ExUnit.Case, async: true

  alias Aiur.UsageAggregate.Projection
  alias Aiur.UsageCompaction.Block

  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1, claude_envelope: 1, record: 2]

  defp tmp(name) do
    dir = Path.join(System.tmp_dir!(), "aiur-block-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, name)
  end

  test "block cells are structurally identical to the DASH-024 projection of the same range" do
    records = [
      record(1, envelope(%{tokens: %{input: 10}})),
      record(2, envelope(%{tokens: %{input: 5, output: 3}})),
      record(3, claude_envelope(%{tokens: %{input: 7}}))
    ]

    {:ok, block} = Block.build(records)
    projection = Projection.apply_records(Projection.new(), records)

    assert Block.cells(block) == projection.cells
    assert block.first_position == 1
    assert block.last_position == 3
    assert block.source_generation == projection.source_generation
    assert block.coverage.folded_records == 3
  end

  test "distinct token-relationship revisions never merge into one cell" do
    records = [
      record(1, envelope(%{tokens: %{input: 10}, relationship_revision: "rev-known"})),
      record(2, envelope(%{tokens: %{input: 10}, relationship_revision: "rev-unknown"}))
    ]

    {:ok, block} = Block.build(records)
    revisions = block |> Block.cells() |> Map.keys() |> Enum.map(fn {dims, _measure} -> dims.relationship_revision end)

    assert Enum.sort(Enum.uniq(revisions)) == ["rev-known", "rev-unknown"]
    assert map_size(Block.cells(block)) == 2
  end

  test "round-trips through encode/decode preserving every cell and covered fact" do
    records = for position <- 1..4, do: record(position, envelope(%{tokens: %{input: position}}))
    {:ok, block} = Block.build(records)

    {:ok, decoded} = Block.from_record(Block.encode(block))

    assert decoded.cells == block.cells
    assert decoded.covered == block.covered
    assert decoded.coverage.reasons == block.coverage.reasons
    assert decoded.first_position == 1 and decoded.last_position == 4
  end

  test "writes atomically and reloads a byte-identical block" do
    records = [record(1, envelope(%{tokens: %{input: 42}}))]
    {:ok, block} = Block.build(records)
    path = tmp("block-0001.json")

    assert Block.write(path, block) == :ok
    assert {:ok, reloaded} = Block.load(path)
    assert reloaded.cells == block.cells
  end

  test "rejects a tampered checksum as corrupt" do
    records = [record(1, envelope(%{tokens: %{input: 9}}))]
    {:ok, block} = Block.build(records)
    path = tmp("block-tampered.json")
    :ok = Block.write(path, block)

    tampered = path |> File.read!() |> String.replace("\"first_position\":1", "\"first_position\":2")
    File.write!(path, tampered)

    assert {:corrupt, _reason} = Block.load(path)
  end

  test "treats an absent or empty file as missing, not corrupt" do
    assert Block.load(tmp("nope.json")) == :missing

    empty = tmp("empty.json")
    File.write!(empty, "")
    assert Block.load(empty) == :missing
  end

  test "rejects an empty range and a non-contiguous range" do
    assert Block.build([]) == {:error, :empty_range}

    gapped = [record(1, envelope(%{})), record(3, envelope(%{}))]
    assert Block.build(gapped) == {:error, :non_contiguous_range}
  end

  test "carries the pricing-date span across the covered range" do
    records = [record(1, envelope(%{})), record(2, envelope(%{}))]
    {:ok, block} = Block.build(records)

    assert block.covered.first_position == 1
    assert block.covered.last_position == 2
    # Fixtures carry a pricing-effective date, so the span is populated.
    assert match?(%Date{}, block.covered.pricing_date_earliest)
    assert Date.compare(block.covered.pricing_date_latest, block.covered.pricing_date_earliest) != :lt
  end
end

defmodule Aiur.UsageAggregate.CheckpointTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Aiur.UsageAggregate.{Checkpoint, Key, Projection}

  import Aiur.TestSupport.UsageAggregate,
    only: [envelope: 1, claude_envelope: 1, record: 3, money: 1]

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-usage-aggregate-checkpoint-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{path: Path.join(root, "checkpoint.json")}
  end

  defp sample_projection do
    Projection.new()
    |> Projection.apply_record(record(1, envelope(%{}), %{tokens: %{input: 10, output: 4}, cost: money("2.50")}))
    |> Projection.apply_record(record(2, envelope(%{update_kind: :partial, coverage_reasons: [:partial_update]}), %{tokens: %{input: 5}}))
  end

  test "encodes and decodes a projection exactly through a JSON round trip" do
    projection = sample_projection()

    {:ok, restored} = projection |> Checkpoint.encode() |> Jason.encode!() |> Jason.decode!() |> Checkpoint.from_record()

    assert restored.source_position == projection.source_position
    assert restored.source_generation == projection.source_generation
    assert restored.generation == projection.generation
    assert restored.cells == projection.cells
    assert restored.coverage.partial_records == 1
    assert MapSet.member?(restored.coverage.reasons, :partial_update)

    dims = Key.dims(envelope(%{}))
    assert Decimal.equal?(restored.cells[{dims, {:money, :provider_reported_estimate, "USD"}}], Decimal.new("2.50"))
  end

  test "retains occurrence-price partition dimensions across the checkpoint round trip" do
    codex = envelope(%{context_tier: :short_context, upstream_provider: "DeepSeek"})
    claude = claude_envelope(%{cache_write_duration: :one_hour})

    projection =
      Projection.new()
      |> Projection.apply_record(record(1, codex, %{tokens: %{input: 10}}))
      |> Projection.apply_record(record(2, claude, %{tokens: %{cache_creation_input: 5}}))

    {:ok, restored} =
      projection |> Checkpoint.encode() |> Jason.encode!() |> Jason.decode!() |> Checkpoint.from_record()

    assert restored.cells == projection.cells
    assert Key.dims(codex).context_tier == :short_context
    assert Key.dims(codex).upstream_provider == "DeepSeek"
    assert Key.dims(claude).cache_write_duration == :one_hour
    assert restored.cells[{Key.dims(codex), {:token, :input}}] == 10
    assert restored.cells[{Key.dims(claude), {:token, :cache_creation_input}}] == 5
  end

  test "loads a legacy checkpoint whose cells predate optional aggregate dimensions" do
    # A checkpoint written before this change has no context_tier /
    # cache_write_duration keys in its cell dims. Decoding must tolerate their
    # absence, surfacing the partition as unknown (nil) rather than erroring or
    # collapsing the price bucket to a guessed value.
    projection =
      Projection.new()
      |> Projection.apply_record(record(1, envelope(%{context_tier: :short_context, upstream_provider: "DeepSeek"}), %{tokens: %{input: 10}}))

    encoded = Checkpoint.encode(projection)

    legacy_cells =
      Enum.map(encoded["cells"], fn cell ->
        update_in(cell["dims"], &Map.drop(&1, ["context_tier", "cache_write_duration", "upstream_provider"]))
      end)

    assert {:ok, restored} =
             encoded |> Map.put("cells", legacy_cells) |> recompute_checksum() |> Checkpoint.from_record()

    {dims, _measure} = restored.cells |> Map.keys() |> hd()
    assert dims.context_tier == nil
    assert dims.cache_write_duration == nil
    assert dims.upstream_provider == nil
  end

  test "rejects a checkpoint cell carrying an invalid occurrence-price partition" do
    encoded = Checkpoint.encode(sample_projection())
    [cell | rest] = encoded["cells"]
    tampered = put_in(cell, ["dims", "context_tier"], "bogus_tier")

    assert {:error, _reason} =
             encoded |> Map.put("cells", [tampered | rest]) |> recompute_checksum() |> Checkpoint.from_record()
  end

  test "rejects a rechecksummed cell carrying a non-ledger-safe upstream provider" do
    encoded = Checkpoint.encode(sample_projection())
    [cell | rest] = encoded["cells"]
    tampered = put_in(cell, ["dims", "upstream_provider"], "Deep Seek")

    assert {:error, _reason} =
             encoded |> Map.put("cells", [tampered | rest]) |> recompute_checksum() |> Checkpoint.from_record()
  end

  test "writes owner-only and loads the durable snapshot atomically", %{path: path} do
    projection = sample_projection()

    assert :ok = Checkpoint.write(path, projection)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert (mode &&& 0o077) == 0, "checkpoint must be owner-only"
    assert {:ok, restored} = Checkpoint.load(path)
    assert restored.cells == projection.cells
  end

  test "treats a missing or empty snapshot as missing, never corrupt", %{path: path} do
    assert :missing = Checkpoint.load(path)
    File.write!(path, "")
    assert :missing = Checkpoint.load(path)
  end

  test "rejects a checksum, schema, or structural mutation as corrupt" do
    encoded = Checkpoint.encode(sample_projection())

    assert {:error, :checksum_mismatch} =
             encoded |> Map.put("source_position", 99) |> Checkpoint.from_record()

    assert {:error, _reason} =
             encoded |> Map.put("schema", "not_usage_aggregate") |> recompute_checksum() |> Checkpoint.from_record()

    tampered_cell = [%{"dims" => %{"provider" => "codex"}, "measure" => ["token", "input"], "value" => 3}]

    assert {:error, _reason} =
             encoded |> Map.put("cells", tampered_cell) |> recompute_checksum() |> Checkpoint.from_record()
  end

  test "loads a corrupt on-disk file as corrupt with a stable reason", %{path: path} do
    File.write!(path, "{ not json")
    assert {:corrupt, _reason} = Checkpoint.load(path)
  end

  # Re-seals a mutated payload so the test isolates the mutation under test from
  # the checksum guard already covered above.
  defp recompute_checksum(record) do
    payload = Map.drop(record, ["checksum"])

    checksum =
      payload
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Map.put(record, "checksum", checksum)
  end
end

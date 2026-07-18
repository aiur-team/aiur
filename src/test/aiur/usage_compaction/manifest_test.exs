defmodule Aiur.UsageCompaction.ManifestTest do
  use ExUnit.Case, async: true

  alias Aiur.UsageCompaction.Manifest

  defp advance_to_finalized(manifest, first, last, ref) do
    {:ok, manifest} = Manifest.prepare(manifest, first, last, ref, last)
    {:ok, manifest} = Manifest.advance(manifest, :aggregate_committed)
    {:ok, manifest} = Manifest.advance(manifest, :source_retired)
    {:ok, manifest} = Manifest.finalize(manifest)
    manifest
  end

  test "a fresh manifest starts at watermark zero with no blocks or pending phase" do
    manifest = Manifest.new(%{min_retained_positions: 10})

    assert manifest.retired_through == 0
    assert Manifest.blocks(manifest) == []
    assert Manifest.pending(manifest) == nil
    assert Manifest.next_position(manifest) == 1
  end

  test "drives one full destructive phase and advances the watermark" do
    manifest = advance_to_finalized(Manifest.new(), 1, 100, "block-1.json")

    assert manifest.retired_through == 100
    assert Manifest.pending(manifest) == nil
    assert [%{first_position: 1, last_position: 100, ref: "block-1.json"}] = Manifest.blocks(manifest)
    assert Manifest.next_position(manifest) == 101
  end

  test "chains contiguous phases into a gapless block cover" do
    manifest =
      Manifest.new()
      |> advance_to_finalized(1, 100, "block-1.json")
      |> advance_to_finalized(101, 250, "block-2.json")

    assert manifest.retired_through == 250
    assert Enum.map(Manifest.blocks(manifest), & &1.last_position) == [100, 250]
  end

  test "rejects a non-contiguous or in-flight prepare" do
    manifest = Manifest.new()
    assert Manifest.prepare(manifest, 5, 10, "b.json", 10) == {:error, :non_contiguous_range}

    {:ok, in_flight} = Manifest.prepare(manifest, 1, 10, "b.json", 10)
    assert Manifest.prepare(in_flight, 11, 20, "c.json", 20) == {:error, :phase_in_flight}
  end

  test "enforces the phase ordering" do
    {:ok, prepared} = Manifest.prepare(Manifest.new(), 1, 10, "b.json", 10)

    assert Manifest.advance(prepared, :source_retired) == {:error, :illegal_transition}
    assert Manifest.finalize(prepared) == {:error, :not_retired}

    {:ok, committed} = Manifest.advance(prepared, :aggregate_committed)
    assert Manifest.finalize(committed) == {:error, :not_retired}
  end

  test "rollback abandons the in-flight phase without moving the watermark" do
    manifest = advance_to_finalized(Manifest.new(), 1, 100, "block-1.json")
    {:ok, in_flight} = Manifest.prepare(manifest, 101, 200, "block-2.json", 200)

    rolled = Manifest.rollback(in_flight)
    assert rolled.retired_through == 100
    assert Manifest.pending(rolled) == nil
    assert length(Manifest.blocks(rolled)) == 1
  end

  test "round-trips through encode/decode at every phase" do
    for build <- [
          fn m -> elem(Manifest.prepare(m, 1, 10, "b.json", 10), 1) end,
          fn m -> m |> then(&elem(Manifest.prepare(&1, 1, 10, "b.json", 10), 1)) |> then(&elem(Manifest.advance(&1, :aggregate_committed), 1)) end,
          fn m -> advance_to_finalized(m, 1, 10, "b.json") end
        ] do
      manifest = build.(Manifest.new(%{retire_batch: 5}))
      {:ok, decoded} = Manifest.from_record(Manifest.encode(manifest))

      assert decoded.retired_through == manifest.retired_through
      assert decoded.pending == manifest.pending
      assert decoded.blocks == manifest.blocks
    end
  end

  test "rejects a tampered checksum and a gapped block cover" do
    manifest = advance_to_finalized(Manifest.new(), 1, 100, "block-1.json")
    encoded = Manifest.encode(manifest)

    tampered = Map.put(encoded, "retired_through", 999)
    assert {:error, _} = Manifest.from_record(tampered)

    gapped = %{
      "schema" => "usage_compaction_manifest",
      "version" => 1,
      "retired_through" => 200,
      "policy" => %{},
      "blocks" => [
        %{"first_position" => 1, "last_position" => 100, "ref" => "b1.json", "source_generation" => 100},
        %{"first_position" => 150, "last_position" => 200, "ref" => "b2.json", "source_generation" => 200}
      ],
      "pending" => nil
    }

    assert {:error, :invalid_manifest} = Manifest.from_record(gapped)
  end

  test "rejects a block ref that tries to escape the blocks directory" do
    escaping = %{
      "schema" => "usage_compaction_manifest",
      "version" => 1,
      "retired_through" => 100,
      "policy" => %{},
      "blocks" => [%{"first_position" => 1, "last_position" => 100, "ref" => "../secret", "source_generation" => 100}],
      "pending" => nil
    }

    assert {:error, :invalid_manifest} = Manifest.from_record(escaping)
  end

  test "writes and loads durably, treating an absent file as missing" do
    dir = Path.join(System.tmp_dir!(), "aiur-manifest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "manifest.json")

    assert Manifest.load(path) == :missing

    manifest = advance_to_finalized(Manifest.new(), 1, 100, "block-1.json")
    assert Manifest.write(path, manifest) == :ok
    assert {:ok, loaded} = Manifest.load(path)
    assert loaded.retired_through == 100
  end
end

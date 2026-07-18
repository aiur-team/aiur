defmodule Aiur.UsageCompaction.Floor do
  @moduledoc false

  # Loads the compacted-coverage floor the DASH-024 aggregate seeds a rebuild
  # from once raw source below the retention watermark has been retired. The
  # floor is the exact merged contribution of every finalized block up to
  # `manifest.retired_through`; folding the retained raw above it reproduces the
  # full pre-compaction projection.
  #
  # A missing manifest means nothing was ever retired — the floor is empty and a
  # rebuild scans raw from position zero as before. A corrupt manifest, a
  # missing/corrupt block, or a block whose range disagrees with the manifest is
  # fatal: the retired prefix cannot be reconstructed, so this returns an error
  # and the caller degrades rather than serving undercounted totals.

  alias Aiur.Config
  alias Aiur.UsageCompaction.{Block, Manifest, Paths}

  @type t :: %{
          source_position: non_neg_integer(),
          source_generation: non_neg_integer(),
          cells: map(),
          coverage: %{folded_records: non_neg_integer(), partial_records: non_neg_integer(), reasons: map()}
        }

  @spec empty() :: t()
  def empty do
    %{source_position: 0, source_generation: 0, cells: %{}, coverage: %{folded_records: 0, partial_records: 0, reasons: MapSet.new()}}
  end

  @doc """
  Loads the floor from the configured compaction state directory. An
  unresolvable directory means no compaction has ever run, so the floor is
  empty and a rebuild scans raw from position zero.
  """
  @spec load() :: {:ok, t()} | {:error, atom()}
  def load do
    case Config.Paths.usage_compaction_state_dir() do
      {:ok, dir} -> load(dir)
      {:error, _reason} -> {:ok, empty()}
    end
  end

  @spec load(String.t()) :: {:ok, t()} | {:error, atom()}
  def load(dir) when is_binary(dir) do
    case Manifest.load(Paths.manifest_path(dir)) do
      :missing -> {:ok, empty()}
      {:ok, manifest} -> from_manifest(dir, manifest)
      {:corrupt, _reason} -> {:error, :manifest_corrupt}
    end
  end

  # Once a phase reaches `source_retired` the raw for its range is committed to
  # deletion but the block that replaces it is still only `pending`, not in the
  # finalized cover. Reconstructing a floor from finalized blocks alone would
  # silently omit that range while the raw is already gone. Fail closed so the
  # aggregate latches unavailable and reconciliation (finalize) runs first,
  # rather than serving undercounted totals. Earlier phases leave raw intact, so
  # a rebuild over the finalized floor plus retained raw is still exact.
  defp from_manifest(_dir, %Manifest{pending: %{phase: :source_retired}}), do: {:error, :destructive_phase_in_flight}

  defp from_manifest(_dir, %Manifest{retired_through: 0}), do: {:ok, empty()}

  defp from_manifest(dir, manifest) do
    Enum.reduce_while(Manifest.blocks(manifest), {:ok, empty()}, fn entry, {:ok, floor} ->
      case load_block(dir, entry) do
        {:ok, block} -> {:cont, {:ok, merge(floor, block)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finalize(manifest)
  end

  defp finalize({:ok, floor}, manifest) do
    if floor.source_position == manifest.retired_through, do: {:ok, floor}, else: {:error, :block_coverage_gap}
  end

  defp finalize({:error, reason}, _manifest), do: {:error, reason}

  defp load_block(dir, entry) do
    case Block.load(Paths.block_path(dir, entry.ref)) do
      {:ok, block} ->
        if block.first_position == entry.first_position and block.last_position == entry.last_position,
          do: {:ok, block},
          else: {:error, :block_range_mismatch}

      :missing ->
        {:error, :block_missing}

      {:corrupt, _reason} ->
        {:error, :block_corrupt}
    end
  end

  defp merge(floor, block) do
    %{
      source_position: max(floor.source_position, block.last_position),
      source_generation: max(floor.source_generation, block.source_generation),
      cells: merge_cells(floor.cells, Block.cells(block)),
      coverage: merge_coverage(floor.coverage, block.coverage)
    }
  end

  defp merge_cells(left, right) do
    Map.merge(left, right, fn _cell, a, b -> add_value(a, b) end)
  end

  defp add_value(%Decimal{} = left, %Decimal{} = right), do: Decimal.add(left, right)
  defp add_value(left, right) when is_integer(left) and is_integer(right), do: left + right

  defp merge_coverage(left, right) do
    %{
      folded_records: left.folded_records + right.folded_records,
      partial_records: left.partial_records + right.partial_records,
      reasons: MapSet.union(left.reasons, right.reasons)
    }
  end
end

defmodule Aiur.UsageCompaction.Paths do
  @moduledoc false

  # Daemon-private path layout for the retention/compaction state directory. It
  # holds the destructive-phase manifest at the root and the finalized compacted
  # blocks under a `blocks/` leaf. Block filenames are derived deterministically
  # from the covered range, so preparing a block path is pure and a crash never
  # leaves an ambiguously-named block.

  alias Aiur.DecisionLog

  @manifest_name "manifest.json"
  @blocks_dir "blocks"

  @spec prepare(String.t(), (-> :ok | {:error, term()})) :: {:ok, map()} | {:error, term()}
  def prepare(root, sync_fun) when is_binary(root) and is_function(sync_fun, 0) do
    blocks_dir = Path.join(root, @blocks_dir)

    with :ok <- DecisionLog.ensure_directory(root),
         :ok <- DecisionLog.ensure_directory(blocks_dir),
         :ok <- sync_fun.() do
      {:ok,
       %{
         root: root,
         manifest_path: Path.join(root, @manifest_name),
         blocks_dir: blocks_dir,
         degraded_path: Path.join(root, "degraded.json"),
         quarantine_dir: Path.join(root, "quarantine")
       }}
    end
  end

  @spec manifest_path(String.t()) :: String.t()
  def manifest_path(root) when is_binary(root), do: Path.join(root, @manifest_name)

  @spec block_path(String.t(), String.t()) :: String.t()
  def block_path(root, ref) when is_binary(root) and is_binary(ref), do: Path.join([root, @blocks_dir, ref])

  @doc "Deterministic block filename for a covered position range."
  @spec block_ref(pos_integer(), pos_integer()) :: String.t()
  def block_ref(first, last) when is_integer(first) and is_integer(last) and first > 0 and last >= first do
    "block-#{pad(first)}-#{pad(last)}.json"
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(16, "0")
end

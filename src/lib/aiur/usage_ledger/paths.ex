defmodule Aiur.UsageLedger.Paths do
  @moduledoc false

  alias Aiur.DecisionLog

  @segment_name "00000001.ndjson"
  @digest_chunk_bytes 64 * 1_024

  @spec prepare(String.t(), (-> :ok | {:error, term()})) :: {:ok, map()} | {:error, term()}
  def prepare(root, sync_fun) when is_binary(root) and is_function(sync_fun, 0) do
    segments_dir = Path.join(root, "segments")
    segment_path = Path.join(segments_dir, @segment_name)

    with :ok <- DecisionLog.ensure_directory(root),
         :ok <- DecisionLog.prepare(segments_dir, segment_path, sync_fun) do
      {:ok,
       %{
         root: root,
         segments_dir: segments_dir,
         segment_path: segment_path,
         checkpoint_path: Path.join(root, "checkpoint.json"),
         degraded_path: Path.join(root, "degraded.json"),
         quarantine_dir: Path.join(root, "quarantine")
       }}
    end
  end

  @spec quarantine(String.t(), String.t(), (-> :ok | {:error, term()})) :: :ok | {:error, term()}
  def quarantine(path, quarantine_dir, sync_fun) when is_binary(path) and is_binary(quarantine_dir) and is_function(sync_fun, 0) do
    with :ok <- DecisionLog.ensure_directory(quarantine_dir),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, digest} <- file_digest(path),
         destination = quarantine_path(path, quarantine_dir, digest),
         :ok <- ensure_quarantine_evidence(path, destination, digest),
         :ok <- sync_fun.() do
      :ok
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_quarantine_evidence(source, destination, digest) do
    case File.lstat(destination) do
      {:error, :enoent} -> create_quarantine_evidence(source, destination, digest)
      {:ok, %File.Stat{type: :regular}} -> reuse_quarantine_evidence(destination, digest)
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_quarantine_evidence(source, destination, digest) do
    pending = destination <> ".pending"

    result =
      with :ok <- regular_or_missing(pending),
           :ok <- File.cp(source, pending),
           :ok <- File.chmod(pending, 0o600),
           :ok <- verify_digest(pending, digest) do
        File.rename(pending, destination)
      end

    if result != :ok, do: discard_pending(pending)
    result
  end

  defp reuse_quarantine_evidence(destination, digest) do
    with :ok <- verify_digest(destination, digest),
         :ok <- File.chmod(destination, 0o600) do
      discard_pending(destination <> ".pending")
    end
  end

  defp verify_digest(path, expected) do
    case file_digest(path) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :quarantine_checksum_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_digest(path) do
    File.open(path, [:read, :binary], fn device ->
      device
      |> IO.binstream(@digest_chunk_bytes)
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, context ->
        :crypto.hash_update(context, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    end)
  end

  defp regular_or_missing(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp discard_pending(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> File.rm(path)
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp quarantine_path(path, quarantine_dir, digest) do
    Path.join(quarantine_dir, "#{Path.basename(path)}.sha256-#{digest}.quarantine")
  end
end

defmodule Aiur.UsageAggregate.Paths do
  @moduledoc false

  # Owner-only state layout for the aggregate projection. The single checkpoint
  # file is pre-created and directory-synced once so the atomic-rename hot path
  # never needs a global filesystem barrier for a brand-new directory entry.

  alias Aiur.{DecisionLog, Fs}

  @digest_chunk_bytes 64 * 1_024

  @spec prepare(String.t(), (-> :ok | {:error, term()})) :: {:ok, map()} | {:error, term()}
  def prepare(root, sync_fun) when is_binary(root) and is_function(sync_fun, 0) do
    checkpoint_path = Path.join(root, "checkpoint.json")

    with :ok <- DecisionLog.ensure_directory(root),
         :ok <- DecisionLog.prepare(root, checkpoint_path, sync_fun) do
      {:ok,
       %{
         root: root,
         checkpoint_path: checkpoint_path,
         degraded_path: Path.join(root, "degraded.json"),
         quarantine_dir: Path.join(root, "quarantine")
       }}
    end
  end

  @doc """
  Preserves a corrupt checkpoint as content-addressed evidence before rebuild.

  Best-effort and idempotent: the destination is keyed by the file digest so a
  repeated recovery of the same corrupt bytes reuses one evidence file.
  """
  @spec quarantine(String.t(), String.t(), (-> :ok | {:error, term()})) :: :ok | {:error, term()}
  def quarantine(path, quarantine_dir, sync_fun)
      when is_binary(path) and is_binary(quarantine_dir) and is_function(sync_fun, 0) do
    with :ok <- DecisionLog.ensure_directory(quarantine_dir),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, digest} <- file_digest(path),
         destination = Path.join(quarantine_dir, "checkpoint.json.sha256-#{digest}.quarantine"),
         :ok <- copy_evidence(path, destination),
         :ok <- sync_fun.() do
      :ok
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_degraded_marker(String.t(), atom(), (-> :ok | {:error, term()})) :: :ok | {:error, term()}
  def write_degraded_marker(path, reason, sync_fun) when is_atom(reason) do
    contents = Jason.encode!(%{"version" => 1, "reason" => Atom.to_string(reason)})

    with :ok <- Fs.atomic_write(path, contents, fsync: true, mode: 0o600) do
      sync_fun.()
    end
  end

  @spec degraded_marker(String.t()) :: :absent | {:degraded, atom()} | {:error, atom()}
  def degraded_marker(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :absent
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 1_024 -> read_marker(path)
      _other -> {:error, :marker_invalid}
    end
  end

  defp read_marker(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"version" => 1, "reason" => reason}} <- Jason.decode(contents),
         {:ok, atom} <- known_reason(reason) do
      {:degraded, atom}
    else
      _other -> {:error, :marker_invalid}
    end
  end

  defp known_reason(reason) when reason in ["checkpoint_corrupt", "source_regressed"] do
    {:ok, String.to_existing_atom(reason)}
  end

  defp known_reason(_reason), do: :error

  defp copy_evidence(source, destination) do
    case File.lstat(destination) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> stage_evidence(source, destination)
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stage_evidence(source, destination) do
    pending = destination <> ".pending"

    result =
      with :ok <- File.cp(source, pending),
           :ok <- File.chmod(pending, 0o600) do
        File.rename(pending, destination)
      end

    if result != :ok, do: File.rm(pending)
    result
  end

  defp file_digest(path) do
    File.open(path, [:read, :binary], fn device ->
      device
      |> IO.binstream(@digest_chunk_bytes)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    end)
  end
end

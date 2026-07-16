defmodule Aiur.UsageLedger.Paths do
  @moduledoc false

  alias Aiur.DecisionLog

  @segment_name "00000001.ndjson"

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
    destination = quarantine_path(path, quarantine_dir)

    with :ok <- DecisionLog.ensure_directory(quarantine_dir),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         :ok <- File.cp(path, destination),
         :ok <- File.chmod(destination, 0o600),
         :ok <- sync_fun.() do
      :ok
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp quarantine_path(path, quarantine_dir) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(quarantine_dir, "#{Path.basename(path)}.#{suffix}.quarantine")
  end
end

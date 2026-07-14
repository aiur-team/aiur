defmodule Aiur.CurrentRunMembership.Store.Paths do
  @moduledoc false

  alias Aiur.DecisionLog

  @spec prepare(String.t(), String.t(), (-> term())) :: {:ok, map()} | {:error, term()}
  def prepare(root, run_id, sync_fun) do
    runs_dir = Path.join(root, "runs")
    run_dir = Path.join(runs_dir, run_leaf(run_id))
    journal_path = Path.join(run_dir, "membership.ndjson")

    with :ok <- DecisionLog.ensure_directory(root),
         :ok <- DecisionLog.ensure_directory(runs_dir),
         :ok <- DecisionLog.prepare(run_dir, journal_path, sync_fun) do
      {:ok,
       %{
         root: root,
         runs_dir: runs_dir,
         run_dir: run_dir,
         run_leaf: run_leaf(run_id),
         journal_path: journal_path,
         checkpoint_path: Path.join(run_dir, "membership.checkpoint.json"),
         degraded_path: Path.join(run_dir, "membership.degraded.json"),
         terminal_verification_path: Path.join(run_dir, "membership.terminal-verification.json")
       }}
    end
  end

  @spec valid_run_id(term()) :: :ok | {:error, :invalid_run_id}
  def valid_run_id(run_id) when is_binary(run_id) and byte_size(run_id) in 1..512 do
    if run_id == String.trim(run_id), do: :ok, else: {:error, :invalid_run_id}
  end

  def valid_run_id(_run_id), do: {:error, :invalid_run_id}

  @spec cleanup_obsolete_runs(String.t(), String.t()) :: :ok | {:error, term()}
  def cleanup_obsolete_runs(runs_dir, active_leaf) do
    with {:ok, entries} <- File.ls(runs_dir) do
      entries
      |> Enum.reject(&(&1 == active_leaf))
      |> Enum.reduce_while(:ok, &cleanup_obsolete_entry(&1, runs_dir, &2))
    end
  end

  defp cleanup_obsolete_entry(entry, runs_dir, :ok) do
    path = Path.join(runs_dir, entry)

    with :ok <- valid_generation_directory(path, entry),
         :ok <- remove_generation(path) do
      {:cont, :ok}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp valid_generation_directory(path, entry) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} when byte_size(entry) == 64 -> :ok
      {:ok, _stat} -> {:error, :unexpected_generation_entry}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_generation(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp run_leaf(run_id) do
    run_id
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

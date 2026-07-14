defmodule Aiur.Workspace.Reconstruction do
  @moduledoc false

  alias Aiur.PathSafety

  @log_copy_chunk_size 64 * 1024

  @doc false
  @spec log_copy_chunk_size() :: pos_integer()
  def log_copy_chunk_size, do: @log_copy_chunk_size

  @spec run(Path.t(), (Path.t() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def run(workspace, prepare) when is_binary(workspace) and is_function(prepare, 1) do
    stage_root = sibling_path(workspace, "stage")
    stage = Path.join(stage_root, Path.basename(workspace))

    try do
      File.mkdir_p!(Path.dirname(workspace))
      File.rm_rf!(stage_root)
      File.mkdir_p!(stage)

      case prepare.(stage) do
        :ok -> promote(stage, stage_root, workspace)
        {:error, _reason} = error -> cleanup_stage(stage_root, error)
        other -> cleanup_stage(stage_root, {:error, {:invalid_reconstruction_result, other}})
      end
    rescue
      error ->
        File.rm_rf(stage_root)
        {:error, error}
    end
  end

  @doc false
  @spec with_log_lock(Path.t(), (-> term())) :: term()
  def with_log_lock(workspace, fun) when is_binary(workspace) and is_function(fun, 0) do
    name = {__MODULE__, Path.expand(workspace)}
    lock_key = {__MODULE__, :log_lock_depth, name}

    case Process.get(lock_key) do
      nil ->
        acquire_log_lock(name)
        Process.put(lock_key, 1)

        try do
          fun.()
        after
          Process.delete(lock_key)
          :ok = :global.unregister_name(name)
        end

      depth ->
        Process.put(lock_key, depth + 1)

        try do
          fun.()
        after
          Process.put(lock_key, depth)
        end
    end
  end

  defp acquire_log_lock(name) do
    case :global.register_name(name, self()) do
      :yes ->
        :ok

      :no ->
        Process.sleep(10)
        acquire_log_lock(name)
    end
  end

  defp promote(stage, stage_root, workspace) do
    with_log_lock(workspace, fn ->
      backup = sibling_path(workspace, "previous")
      File.rm_rf!(backup)

      result = promote_stage(stage, workspace, backup)
      File.rm_rf!(stage_root)
      result
    end)
  end

  defp promote_stage(stage, workspace, backup) do
    case move_current_workspace(workspace, backup) do
      :ok -> rename_staged_workspace(stage, workspace, backup)
      {:error, reason} -> {:error, {:workspace_backup_failed, reason}}
    end
  end

  defp rename_staged_workspace(stage, workspace, backup) do
    case File.rename(stage, workspace) do
      :ok ->
        finish_promotion(backup, workspace)

      {:error, reason} ->
        restore_current_workspace(backup, workspace)
        File.rm_rf!(stage)
        {:error, {:workspace_promotion_failed, reason}}
    end
  end

  defp move_current_workspace(workspace, backup) do
    if File.exists?(workspace) do
      File.rename(workspace, backup)
    else
      :ok
    end
  end

  defp restore_current_workspace(backup, workspace) do
    if File.exists?(backup) and not File.exists?(workspace), do: File.rename(backup, workspace)
    :ok
  end

  defp finish_promotion(backup, workspace) do
    case merge_logs(backup, workspace) do
      :ok ->
        File.rm_rf!(backup)
        :ok

      {:error, reason} ->
        rollback_promoted_workspace(backup, workspace)
        {:error, {:workspace_log_merge_failed, reason}}
    end
  end

  defp rollback_promoted_workspace(backup, workspace) do
    File.rm_rf!(workspace)

    if File.exists?(backup) do
      File.rename(backup, workspace)
    end

    :ok
  end

  # Promotion preserves the complete safe logs subtree, not just the two
  # AgentEventLog files. Providers can leave diagnostic traces beside them;
  # dropping those files makes interrupted-workspace recovery lossy.
  defp merge_logs(previous_workspace, workspace) do
    previous_logs = Path.join(previous_workspace, "logs")

    case File.lstat(previous_logs) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        merge_log_tree(previous_logs, Path.join(workspace, "logs"), workspace)

      {:ok, _stat} ->
        {:error, :unsafe_log_tree}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_log_tree(previous, destination, workspace) do
    with {:ok, entries} <- File.ls(previous),
         :ok <- ensure_safe_log_directory(destination, workspace) do
      merge_log_entries(entries, previous, destination, workspace)
    end
  end

  defp merge_log_entries(entries, previous, destination, workspace) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case merge_log_entry(Path.join(previous, entry), Path.join(destination, entry), workspace) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp merge_log_entry(source, target, workspace) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :regular}} -> append_previous_log(source, target, workspace)
      {:ok, %File.Stat{type: :directory}} -> merge_log_tree(source, target, workspace)
      {:ok, _stat} -> {:error, :unsafe_log_entry}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_previous_log(previous, destination, workspace) do
    with :ok <- ensure_safe_log_directory(Path.dirname(destination), workspace) do
      atomically_merge_log_files(previous, destination)
    end
  end

  defp atomically_merge_log_files(previous, destination) do
    temporary = log_merge_path(destination)

    try do
      case write_merged_log(temporary, previous, destination) do
        :ok -> File.rename(temporary, destination)
        {:error, _reason} = error -> error
      end
    after
      File.rm(temporary)
    end
  end

  defp write_merged_log(temporary, previous, destination) do
    case File.open(temporary, [:write, :binary, :exclusive]) do
      {:ok, output} ->
        try do
          case stream_regular_file(previous, output) do
            :ok -> stream_optional_regular_file(destination, output)
            {:error, _reason} = error -> error
          end
        after
          File.close(output)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_optional_regular_file(path, output) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> stream_regular_file(path, output)
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :unsafe_log_destination}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_regular_file(path, output) do
    case File.open(path, [:read, :binary]) do
      {:ok, input} ->
        try do
          copy_log_chunks(input, output)
        after
          File.close(input)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_log_chunks(input, output) do
    case IO.binread(input, @log_copy_chunk_size) do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}

      chunk when is_binary(chunk) ->
        :ok = IO.binwrite(output, chunk)
        copy_log_chunks(input, output)
    end
  end

  # Never follow a staged symlink while merging live diagnostics. Each parent
  # is lstat-checked before creation so a hook cannot redirect recovery writes
  # outside its staged checkout.
  defp ensure_safe_log_directory(path, workspace) do
    with :ok <- ensure_log_destination_contained(workspace, path) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, _stat} -> {:error, :unsafe_log_destination}
        {:error, :enoent} -> create_safe_log_directory(path, workspace)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_safe_log_directory(path, workspace) do
    parent = Path.dirname(path)

    with :ok <- ensure_safe_log_directory(parent, workspace),
         :ok <- File.mkdir(path) do
      :ok
    else
      {:error, :eexist} -> ensure_safe_log_directory(path, workspace)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_log_destination_contained(workspace, destination) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(workspace),
         {:ok, _containment} <- PathSafety.contained?(workspace, destination) do
      :ok
    else
      {:ok, _stat} -> {:error, :unsafe_log_destination}
      {:error, :outside_root} -> {:error, :unsafe_log_destination}
      {:error, :unreadable} -> {:error, :unsafe_log_destination}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_stage(stage, error) do
    File.rm_rf!(stage)
    error
  end

  defp sibling_path(workspace, kind) do
    parent = Path.dirname(workspace)
    basename = Path.basename(workspace)
    token = System.unique_integer([:positive, :monotonic])
    Path.join(parent, ".#{basename}.aiur-#{kind}-#{token}")
  end

  defp log_merge_path(destination) do
    parent = Path.dirname(destination)
    basename = Path.basename(destination)
    token = System.unique_integer([:positive, :monotonic])
    Path.join(parent, ".#{basename}.aiur-log-merge-#{token}")
  end
end

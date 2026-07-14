defmodule Aiur.Workspace.Reconstruction do
  @moduledoc false

  # AgentEventLog writes both projections for every event. Keep the paths
  # explicit so promotion can merge the prior stream ahead of anything a hook
  # wrote in its staging checkout without treating the live workspace as a
  # scratch directory.
  @agent_log_files ["agent.ndjson", "agent.md"]

  @spec run(Path.t(), (Path.t() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def run(workspace, prepare) when is_binary(workspace) and is_function(prepare, 1) do
    stage = sibling_path(workspace, "stage")

    try do
      File.mkdir_p!(Path.dirname(workspace))
      File.rm_rf!(stage)
      File.mkdir_p!(stage)

      case prepare.(stage) do
        :ok -> promote(stage, workspace)
        {:error, _reason} = error -> cleanup_stage(stage, error)
        other -> cleanup_stage(stage, {:error, {:invalid_reconstruction_result, other}})
      end
    rescue
      error ->
        File.rm_rf(stage)
        {:error, error}
    end
  end

  @doc false
  @spec with_log_lock(Path.t(), (-> term())) :: term()
  def with_log_lock(workspace, fun) when is_binary(workspace) and is_function(fun, 0) do
    :global.trans({__MODULE__, Path.expand(workspace)}, fun)
  end

  defp promote(stage, workspace) do
    with_log_lock(workspace, fn ->
      backup = sibling_path(workspace, "previous")
      File.rm_rf!(backup)

      promote_stage(stage, workspace, backup)
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
    case merge_agent_logs(backup, workspace) do
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

  defp merge_agent_logs(previous_workspace, workspace) do
    Enum.reduce_while(@agent_log_files, :ok, fn filename, :ok ->
      case merge_agent_log(previous_workspace, workspace, filename) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp merge_agent_log(previous_workspace, workspace, filename) do
    previous = Path.join([previous_workspace, "logs", filename])

    if File.regular?(previous) do
      append_previous_agent_log(previous, workspace, filename)
    else
      :ok
    end
  end

  defp append_previous_agent_log(previous, workspace, filename) do
    destination = Path.join([workspace, "logs", filename])

    with {:ok, previous_contents} <- File.read(previous),
         {:ok, staged_contents} <- read_optional_file(destination),
         :ok <- File.mkdir_p(Path.dirname(destination)) do
      File.write(destination, previous_contents <> staged_contents)
    end
  end

  defp read_optional_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:ok, ""}
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
end

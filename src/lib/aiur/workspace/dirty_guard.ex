defmodule Aiur.Workspace.DirtyGuard do
  @moduledoc "Prevents Aiur from deleting a checkout with uncommitted work."

  require Logger

  alias Aiur.{Signal, Config}
  alias Aiur.Workspace.Remote

  @timeout_ms 5_000
  @dirty_status 75

  @spec check(Path.t(), String.t() | nil) :: :ok | {:error, {:workspace_not_safe_to_delete, Path.t(), term()}}
  @spec check(Path.t(), String.t() | nil, keyword()) :: :ok | {:error, {:workspace_not_safe_to_delete, Path.t(), term()}}
  def check(workspace, worker_host, opts \\ [])

  def check(workspace, nil, opts) do
    if File.exists?(Path.join(workspace, ".git")) do
      task =
        Task.async(fn ->
          try do
            System.cmd("git", ["-C", workspace, "status", "--porcelain", "--untracked-files=all"],
              stderr_to_stdout: true,
              env: [{"GIT_OPTIONAL_LOCKS", "0"}]
            )
          rescue
            error -> {:error, error}
          end
        end)

      case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {"", 0}} -> :ok
        {:ok, {:error, reason}} -> refuse(workspace, reason, opts)
        {:ok, {_output, 0}} -> refuse(workspace, :dirty, opts)
        {:ok, {_output, status}} -> refuse(workspace, {:git_status_failed, status}, opts)
        _ -> refuse(workspace, :git_status_timeout, opts)
      end
    else
      :ok
    end
  end

  def check(workspace, worker_host, opts) when is_binary(worker_host) do
    script = Remote.remote_shell_assign("workspace", workspace) <> "\n" <> remote_check_script()

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, @dirty_status}} -> refuse(workspace, :dirty, opts)
      {:ok, {_output, status}} -> refuse(workspace, {:git_status_failed, status}, opts)
      {:error, reason} -> refuse(workspace, reason, opts)
    end
  end

  @spec remote_check_script() :: String.t()
  def remote_check_script do
    """
    if [ -e "$workspace/.git" ]; then
      status=$(GIT_OPTIONAL_LOCKS=0 git -C "$workspace" status --porcelain --untracked-files=all 2>/dev/null) || exit 76
      [ -z "$status" ] || exit #{@dirty_status}
    fi
    """
  end

  @spec refuse(Path.t(), term()) :: {:error, {:workspace_not_safe_to_delete, Path.t(), term()}}
  @spec refuse(Path.t(), term(), keyword()) :: {:error, {:workspace_not_safe_to_delete, Path.t(), term()}}
  def refuse(workspace, reason, opts \\ []) do
    Logger.warning("Keeping workspace instead of deleting unpreserved work workspace=#{workspace} reason=#{inspect(reason)}")
    ticket = Path.basename(workspace)

    if Keyword.get(opts, :alert?, true) do
      Signal.alert("ticket.#{ticket}.workspace.dirty_kept",
        message: "Aiur kept #{workspace} because its work could not be safely deleted (#{inspect(reason)}). Commit, stash, or copy the work before retrying the ticket.",
        needs_attention: true,
        workspace: workspace
      )
    end

    {:error, {:workspace_not_safe_to_delete, workspace, reason}}
  end
end

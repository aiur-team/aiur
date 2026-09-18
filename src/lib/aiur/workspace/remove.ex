defmodule Aiur.Workspace.Remove do
  @moduledoc """
  Workspace removal: local and remote rm-rf with before_remove hook dispatch
  and per-issue multi-host fanout.

  A local checkout with uncommitted work is saved by
  `Aiur.Workspace.WipPreservation` before it is removed, and is kept when the
  save fails. A dirty remote checkout is never removed (#2743).
  """

  alias Aiur.Config
  alias Aiur.Workspace.{Hooks, Layout, Remote, WipPreservation}

  # Exit status of the remote removal script when the checkout is dirty.
  @remote_dirty_status 75

  @type worker_host :: String.t() | nil

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case Layout.validate_workspace_path(workspace, nil) do
          :ok ->
            remove_preserved(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        Remote.remote_shell_assign("workspace", workspace),
        "if [ -e \"$workspace/.git\" ] && [ -n \"$(git -C \"$workspace\" status --porcelain --untracked-files=all 2>/dev/null | head -n 1)\" ]; then",
        "  echo 'workspace has uncommitted changes; not removed' >&2",
        "  exit #{@remote_dirty_status}",
        "fi",
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {_output, @remote_dirty_status}} ->
        {:error, reason} =
          WipPreservation.refuse(workspace, Path.basename(workspace), "remove the workspace on #{worker_host}", :remote_worker_unsupported)

        {:error, reason, ""}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host)
      when is_binary(identifier) and is_binary(worker_host) do
    safe_id = Layout.safe_identifier(identifier)

    case Layout.workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = Layout.safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case Layout.workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  defp remove_preserved(workspace) do
    case WipPreservation.guard_destroy(workspace, Path.basename(workspace), "remove the workspace", fn ->
           maybe_run_before_remove_hook(workspace, nil)
           File.rm_rf(workspace)
         end) do
      {:error, {:wip_preservation_failed, _workspace, _reason} = reason} -> {:error, reason, ""}
      result -> result
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            Hooks.run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> Hooks.ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            Remote.remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            Hooks.handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> Hooks.ignore_hook_failure()
    end
  end
end

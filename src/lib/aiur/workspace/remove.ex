defmodule Aiur.Workspace.Remove do
  @moduledoc """
  Workspace removal: local and remote rm-rf with before_remove hook dispatch
  and per-issue multi-host fanout.

  A local checkout with uncommitted work is saved by
  `Aiur.Workspace.WipPreservation` before it is removed, and is kept when the
  save fails. A dirty remote checkout is not removed until an operator
  authorizes the discard (#2743).

  Options of `remove/3` and `remove_issue_workspaces/3`:

    * `ticket` - the ticket named in alerts (default: the workspace leaf);
    * `terminal?` - the ticket is closed. A save that times out then gives a
      manifest-only save and the delete proceeds, and a refusal says the
      ticket is closed instead of held;
    * `keep_dirty?` - leave a dirty workspace in place without a save. The
      startup todo cleanup uses it, so the Orchestrator runs only one short
      `git status`; the dispatch-time recreate saves the work in the runner.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.Workspace.{Hooks, Layout, Remote, WipPreservation}

  # Exit status of the remote removal script when the checkout is dirty.
  @remote_dirty_status 75

  @type worker_host :: String.t() | nil

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil, [])

  @spec remove(Path.t(), worker_host(), keyword()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, worker_host, opts \\ [])

  def remove(workspace, nil, opts) do
    case File.exists?(workspace) do
      true ->
        case Layout.validate_workspace_path(workspace, nil) do
          :ok ->
            remove_local(workspace, opts)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host, opts) when is_binary(worker_host) do
    leaf = Path.basename(workspace)
    discard? = WipPreservation.discard_authorized?(leaf)
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        Remote.remote_shell_assign("workspace", workspace),
        unless(discard?, do: remote_dirty_check()),
        "rm -rf \"$workspace\""
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        if discard?, do: WipPreservation.emit_discarded_alert(ticket(workspace, opts), "#{worker_host}:#{workspace}", :remote_worker_unsupported)
        WipPreservation.consume_discard(leaf)
        WipPreservation.clear_hold(leaf)
        {:ok, []}

      {:ok, {_output, @remote_dirty_status}} ->
        remote_dirty(workspace, worker_host, opts)

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp remote_dirty_check do
    [
      "if [ -e \"$workspace/.git\" ] && [ -n \"$(git -C \"$workspace\" status --porcelain --untracked-files=normal 2>/dev/null | head -n 1)\" ]; then",
      "  echo 'workspace has uncommitted changes; not removed' >&2",
      "  exit #{@remote_dirty_status}",
      "fi"
    ]
    |> Enum.join("\n")
  end

  defp remote_dirty(workspace, worker_host, opts) do
    if Keyword.get(opts, :keep_dirty?, false) do
      Logger.info("Kept dirty remote workspace for its next dispatch workspace=#{workspace} worker_host=#{worker_host}")
      {:error, {:workspace_dirty_kept, workspace}, ""}
    else
      {:error, reason} =
        WipPreservation.refuse(workspace, ticket(workspace, opts), "remove the workspace on #{worker_host}", :remote_worker_unsupported, terminal?: Keyword.get(opts, :terminal?, false))

      {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil, [])

  @spec remove_issue_workspaces(term(), worker_host(), keyword()) :: :ok
  def remove_issue_workspaces(identifier, worker_host, opts \\ [])

  def remove_issue_workspaces(identifier, worker_host, opts)
      when is_binary(identifier) and is_binary(worker_host) do
    safe_id = Layout.safe_identifier(identifier)

    case Layout.workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host, Keyword.put_new(opts, :ticket, identifier))
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil, opts) when is_binary(identifier) do
    safe_id = Layout.safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case Layout.workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil, Keyword.put_new(opts, :ticket, identifier))
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1, opts))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host, _opts) do
    :ok
  end

  defp remove_local(workspace, opts) do
    if Keyword.get(opts, :keep_dirty?, false),
      do: remove_unless_dirty(workspace),
      else: remove_preserved(workspace, opts)
  end

  defp remove_unless_dirty(workspace) do
    case WipPreservation.dirty?(workspace) do
      {:ok, false} ->
        maybe_run_before_remove_hook(workspace, nil)
        File.rm_rf(workspace)

      {:ok, true} ->
        Logger.info("Kept dirty workspace for its next dispatch, which saves the work before any recreate workspace=#{workspace}")
        {:error, {:workspace_dirty_kept, workspace}, ""}

      {:error, reason} ->
        Logger.warning("Kept workspace whose state could not be checked workspace=#{workspace} reason=#{inspect(reason)}")
        {:error, reason, ""}
    end
  end

  defp remove_preserved(workspace, opts) do
    destroy = fn ->
      maybe_run_before_remove_hook(workspace, nil)
      File.rm_rf(workspace)
    end

    case WipPreservation.guard_destroy(workspace, ticket(workspace, opts), "remove the workspace", destroy, Keyword.take(opts, [:terminal?])) do
      {:error, {:wip_preservation_failed, _workspace, _reason} = reason} -> {:error, reason, ""}
      result -> result
    end
  end

  defp ticket(workspace, opts), do: Keyword.get(opts, :ticket) || Path.basename(workspace)

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

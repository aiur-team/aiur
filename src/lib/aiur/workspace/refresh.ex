defmodule Aiur.Workspace.Refresh do
  @moduledoc "Before-run hook dispatch: run the hook, then finalize (git metadata + bootstrap seed). Handles the dirty-leftover recreation path (#577), which saves uncommitted work before it deletes anything (#2743), and the in-flight WIP skip (#653)."

  require Logger
  alias Aiur.{AgentBuildGuard, Config}
  alias Aiur.Workspace.{BootstrapImage, Context, GitMetadata, Hooks, Ownership, Provisioner, Reconstruction, WipPreservation}

  @spec run(Path.t(), map() | String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def run(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context =
      issue_or_identifier
      |> Context.build()
      |> then(&%{&1 | branch_name: Provisioner.resolve_branch_name(workspace, &1)})

    case refresh_workspace_readiness(workspace, worker_host) do
      {:error, _reason} = error ->
        error

      _readiness ->
        hooks = Config.settings!().hooks
        hook_result = run_before_run_command(hooks.before_run, workspace, issue_context, worker_host)

        case hook_result do
          :ok ->
            finalize_before_run_workspace(workspace, issue_context, worker_host)

          {:error, reason} = error ->
            maybe_recreate_stale_workspace(
              error,
              reason,
              hooks.before_run,
              workspace,
              issue_context,
              worker_host
            )
        end
    end
  end

  @doc false
  @spec maybe_recreate_stale_workspace(
          {:error, term()},
          term(),
          String.t() | nil,
          Path.t(),
          map(),
          String.t() | nil
        ) :: :ok | {:error, term()}
  def maybe_recreate_stale_workspace(
        error,
        reason,
        before_run,
        workspace,
        issue_context,
        worker_host
      ) do
    cond do
      is_nil(before_run) ->
        error

      not stale_leftover_refresh_refusal?(reason) ->
        error

      Ownership.protected?(issue_context.issue_identifier) ->
        Logger.warning(
          "Refusing stale workspace recreation while an active generation owns it #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)}"
        )

        {:error, {:workspace_owned, Ownership.current(issue_context.issue_identifier)}}

      # A fresh todo dispatch that lands on a dirty *leftover* workspace
      # (#577): recreate the workspace clean off the configured base and re-run
      # before_run. The dirty content can still be an agent's unsaved work (a
      # restart mid-turn, #2743), so it is saved outside the workspace first.
      # If it cannot be saved, the workspace is not touched and the ticket is
      # held on the named reason.
      Context.todo_dispatch?(issue_context) ->
        Logger.warning(
          "Recreating stale leftover workspace after before_run dirty-refresh refusal #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)}"
        )

        with :ok <- preserve_then_recreate(workspace, issue_context, worker_host),
             :ok <- run_before_run_command(before_run, workspace, issue_context, worker_host),
             :ok <- finalize_before_run_workspace(workspace, issue_context, worker_host) do
          # Recreation deleted the support tree `create_for_issue/3` installed
          # (#2697). Reinstall all of it, not only the build wrappers.
          Provisioner.maybe_install_agent_support(workspace, worker_host)
        end

      # An in-flight / resumed agent (NOT a todo dispatch) whose "dirty"
      # workspace is its legitimate uncommitted WIP (#653). A base-branch
      # push (PR merge) or a resume-after-idle fires before_run, which
      # refuses to refresh from the configured base while tracked changes are
      # present (#569's guard). For a live agent that refusal must NOT be
      # fatal: skip the configured-base refresh and let the agent keep working
      # on its branch (it rebases/merges at PR time anyway). Returning :ok
      # here is what prevents the `Agent run failed -> 3 retries ->
      # retry_exhausted` chain that used to kill every other in-flight
      # agent on each PR merge.
      true ->
        Logger.info(
          "Skipping before_run configured-base refresh: agent has uncommitted WIP, continuing on its branch #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)}"
        )

        finalize_before_run_workspace(workspace, issue_context, worker_host)
    end
  end

  defp preserve_then_recreate(workspace, issue_context, nil) do
    WipPreservation.guard_destroy(workspace, issue_context.issue_identifier, "recreate the stale workspace", fn ->
      Provisioner.recreate(workspace, nil, issue_context.pr_head_ref, issue_context.branch_name)
    end)
  end

  # The dirty state of a remote checkout cannot be saved to this daemon's
  # runtime state directory, and the exit-65 refusal already proves the
  # checkout is dirty. Hold the ticket instead of deleting the work.
  defp preserve_then_recreate(workspace, issue_context, worker_host) when is_binary(worker_host) do
    WipPreservation.refuse(
      workspace,
      issue_context.issue_identifier,
      "recreate the stale workspace on #{worker_host}",
      :remote_worker_unsupported
    )
  end

  defp finalize_before_run_workspace(workspace, issue_context, worker_host) do
    with :ok <- GitMetadata.ensure_git_metadata_writable(workspace, worker_host) do
      BootstrapImage.maybe_seed(workspace, issue_context, worker_host)
    end
  end

  defp refresh_workspace_readiness(workspace, worker_host) do
    case Provisioner.workspace_readiness(workspace) do
      {:error, {:workspace_ambiguous, _workspace, :invalid_git_checkout}} = error ->
        case GitMetadata.ensure_git_metadata_writable(workspace, worker_host) do
          :ok -> error
          {:error, _reason} = metadata_error -> metadata_error
        end

      readiness ->
        readiness
    end
  end

  defp run_before_run_command(nil, _workspace, _issue_context, _worker_host), do: :ok

  defp run_before_run_command(command, workspace, issue_context, nil) do
    case Provisioner.workspace_readiness(workspace) do
      :bootstrap ->
        reconstruct_before_run_workspace(command, workspace, issue_context)

      :ready ->
        Hooks.run_hook(command, workspace, issue_context, "before_run", nil)

      {:error, _reason} = error ->
        error
    end
  end

  defp run_before_run_command(command, workspace, issue_context, worker_host)
       when is_binary(worker_host) do
    Hooks.run_hook(command, workspace, issue_context, "before_run", worker_host)
  end

  # Promotion replaces the whole workspace, so the agent support tree from
  # `create_for_issue/3` is gone. Install the full local set on the promoted
  # path: the GitHub guard, gh config and quota dirs, skills and scratch, not
  # only the build wrappers the staged hook needed (#2697).
  defp reconstruct_before_run_workspace(command, workspace, issue_context) do
    with :ok <- Reconstruction.run(workspace, &prepare_reconstructed_workspace(&1, command, issue_context)) do
      Provisioner.maybe_install_agent_support(workspace, nil)
    end
  end

  defp prepare_reconstructed_workspace(stage, command, issue_context) do
    with :ok <- Hooks.run_reconstruction_hook(command, stage, issue_context, "before_run"),
         :ok <- GitMetadata.ensure_agent_logs_excluded(stage, nil) do
      AgentBuildGuard.install(stage)
    end
  end

  defp stale_leftover_refresh_refusal?({:workspace_hook_failed, "before_run", 65, _output}),
    do: true

  defp stale_leftover_refresh_refusal?(_reason), do: false
end

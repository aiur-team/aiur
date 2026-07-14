defmodule Aiur.Workspace.Refresh do
  @moduledoc "Before-run hook dispatch: run the hook, then finalize (git metadata + bootstrap seed). Handles the dirty-leftover recreation path (#577) and the in-flight WIP skip (#653)."

  require Logger
  alias Aiur.Config
  alias Aiur.Workspace.{BootstrapImage, Context, GitMetadata, Hooks, Ownership, Provisioner, Reconstruction}

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
      # (#577): the dirty content is not this agent's WIP, so recreate the
      # workspace clean off the configured base and re-run before_run.
      Context.todo_dispatch?(issue_context) ->
        Logger.warning(
          "Recreating stale leftover workspace after before_run dirty-refresh refusal #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)}"
        )

        with :ok <-
               Provisioner.recreate(
                 workspace,
                 worker_host,
                 issue_context.pr_head_ref,
                 issue_context.branch_name
               ),
             :ok <- run_before_run_command(before_run, workspace, issue_context, worker_host) do
          finalize_before_run_workspace(workspace, issue_context, worker_host)
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
        Reconstruction.run(workspace, fn stage ->
          Hooks.run_hook(command, stage, issue_context, "before_run", nil)
        end)

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

  defp stale_leftover_refresh_refusal?({:workspace_hook_failed, "before_run", 65, _output}),
    do: true

  defp stale_leftover_refresh_refusal?(_reason), do: false
end

defmodule Aiur.Workspace.Refresh do
  @moduledoc "Before-run hook dispatch: run the hook, then finalize (git metadata + bootstrap seed). Handles the dirty-leftover recreation path (#577) and the in-flight WIP skip (#653)."

  require Logger
  alias Aiur.Config
  alias Aiur.Workspace.{BootstrapImage, Context, GitMetadata, Hooks, Provisioner}

  @spec run(Path.t(), map() | String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def run(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = Context.build(issue_or_identifier)
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

  @doc false
  def maybe_recreate_stale_workspace(error, reason, before_run, workspace, issue_context, worker_host) do
    cond do
      is_nil(before_run) ->
        error

      not stale_leftover_refresh_refusal?(reason) ->
        error

      # A fresh todo dispatch that lands on a dirty *leftover* workspace
      # (#577): the dirty content is not this agent's WIP, so recreate the
      # workspace clean off origin/main and re-run before_run.
      Context.todo_dispatch?(issue_context) ->
        Logger.warning(
          "Recreating stale leftover workspace after before_run dirty-refresh refusal #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)}"
        )

        with :ok <- Provisioner.recreate(workspace, worker_host),
             :ok <- run_before_run_command(before_run, workspace, issue_context, worker_host) do
          finalize_before_run_workspace(workspace, issue_context, worker_host)
        end

      # An in-flight / resumed agent (NOT a todo dispatch) whose "dirty"
      # workspace is its legitimate uncommitted WIP (#653). A base-branch
      # push (PR merge) or a resume-after-idle fires before_run, which
      # refuses to refresh from origin/main while tracked changes are
      # present (#569's guard). For a live agent that refusal must NOT be
      # fatal: skip the origin/main refresh and let the agent keep working
      # on its branch (it rebases/merges at PR time anyway). Returning :ok
      # here is what prevents the `Agent run failed -> 3 retries ->
      # retry_exhausted` chain that used to kill every other in-flight
      # agent on each PR merge.
      true ->
        Logger.info(
          "Skipping before_run origin/main refresh: agent has uncommitted WIP, continuing on its branch #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)}"
        )

        finalize_before_run_workspace(workspace, issue_context, worker_host)
    end
  end

  defp finalize_before_run_workspace(workspace, issue_context, worker_host) do
    with :ok <- GitMetadata.ensure_git_metadata_writable(workspace, worker_host) do
      BootstrapImage.maybe_seed(workspace, issue_context, worker_host)
    end
  end

  defp run_before_run_command(nil, _workspace, _issue_context, _worker_host), do: :ok

  defp run_before_run_command(command, workspace, issue_context, worker_host) do
    Hooks.run_hook(command, workspace, issue_context, "before_run", worker_host)
  end

  defp stale_leftover_refresh_refusal?({:workspace_hook_failed, "before_run", 65, _output}), do: true
  defp stale_leftover_refresh_refusal?(_reason), do: false
end

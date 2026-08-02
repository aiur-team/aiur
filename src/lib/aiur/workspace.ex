defmodule Aiur.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias Aiur.Alerts
  alias Aiur.Workspace.{Checkout, Context, GitMetadata, Hooks, Layout, Provisioner, Reconstruction, Refresh, Remove}

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil, opts \\ []) do
    issue_context = Context.build(issue_or_identifier)

    try do
      safe_id = Layout.safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- Layout.workspace_path_for_issue(safe_id, worker_host),
           :ok <- Layout.validate_workspace_path(workspace, worker_host) do
        provision_workspace(workspace, worker_host, issue_context, Keyword.get(opts, :lifecycle))
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{Context.log_context(issue_context)} worker_host=#{Context.worker_host_for_log(worker_host)} error=#{Exception.message(error)}")

        {:error, error}
    end
  end

  @doc false
  @spec materialize_from_base(Path.t(), Path.t()) :: :ok | {:error, term()}
  defdelegate materialize_from_base(base, workspace), to: Aiur.Workspace.Materialize

  @doc false
  @spec materialize_from_base(Path.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  defdelegate materialize_from_base(base, workspace, pr_head_ref), to: Aiur.Workspace.Materialize

  @doc false
  @spec materialize_from_base(Path.t(), Path.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  defdelegate materialize_from_base(base, workspace, branch_name, pr_head_ref),
    to: Aiur.Workspace.Materialize

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  defdelegate remove(workspace), to: Remove

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  defdelegate remove(workspace, worker_host), to: Remove

  @spec remove_issue_workspaces(term()) :: :ok
  defdelegate remove_issue_workspaces(identifier), to: Remove

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  defdelegate remove_issue_workspaces(identifier, worker_host), to: Remove

  defp provision_workspace(workspace, worker_host, issue_context, lifecycle) do
    issue_context = %{
      issue_context
      | branch_name: Provisioner.resolve_branch_name(workspace, issue_context)
    }

    # An event writer may have created a safe `logs/` tree before this
    # generation owns the workspace. Unlike a fresh empty directory, that
    # pre-existing state must be promoted to a usable checkout by after_create
    # before it can receive an agent cwd.
    verify_logs_only_bootstrap? = Provisioner.logs_only_workspace?(workspace, worker_host)

    with {:ok, workspace, created?} <-
           Provisioner.ensure_workspace(
             workspace,
             worker_host,
             issue_context.pr_head_ref,
             issue_context.branch_name,
             lifecycle
           ),
         :ok <- Provisioner.ensure_workspace_usable(workspace, worker_host, created?),
         bootstrap? <- Provisioner.bootstrap_required?(workspace, worker_host, created?),
         :ok <- Hooks.run_after_create(workspace, issue_context, bootstrap?, worker_host),
         :ok <- verify_logs_only_bootstrap(workspace, worker_host, verify_logs_only_bootstrap?),
         :ok <- GitMetadata.ensure_agent_logs_excluded(workspace, worker_host),
         :ok <- Hooks.run_github_preflight(workspace, issue_context, worker_host),
         :ok <- Provisioner.maybe_install_agent_skills(workspace, worker_host),
         :ok <- Provisioner.mark_workspace_ready(workspace, worker_host) do
      {:ok, workspace}
    else
      {:error, _reason} = error ->
        cleanup_incomplete_workspace(workspace, worker_host)
        error
    end
  end

  # A failed provisioning attempt must not leave a half-created directory
  # behind for the next dispatch to inherit (#1317): it looks present, but a
  # dispatched agent can't do anything in it. Only remove what this attempt
  # left incomplete — a workspace that is already a genuine checkout (e.g. a
  # transient GitHub preflight failure against otherwise-good content) is left
  # untouched.
  defp cleanup_incomplete_workspace(workspace, nil) do
    Reconstruction.with_log_lock(workspace, fn ->
      unless Checkout.valid_workspace?(workspace) do
        File.rm_rf(workspace)
      end
    end)

    :ok
  end

  # Remote cleanup is out of scope here: the remote prepare script already
  # refuses to hand back an unproven non-empty directory before hooks run.
  defp cleanup_incomplete_workspace(_workspace, worker_host) when is_binary(worker_host), do: :ok

  defp verify_logs_only_bootstrap(_workspace, _worker_host, false), do: :ok

  # A pre-provisioning logs directory is safe only as input to the bootstrap
  # hook. Recheck the promoted workspace before writing Aiur's completion
  # marker so a successful but no-op hook can never turn logs-only content into
  # a provider cwd.
  defp verify_logs_only_bootstrap(workspace, worker_host, true),
    do: Provisioner.ensure_workspace_usable(workspace, worker_host, false)

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    with :ok <- Refresh.run(workspace, issue_or_identifier, worker_host) do
      ensure_dispatch_ready(workspace, issue_or_identifier, worker_host)
    end
  end

  # Refresh/create_for_issue can both report success while the workspace on
  # disk is not actually a usable checkout (a lost promotion is the concrete
  # case fixed by #1317). This is the last gate before an agent turn starts,
  # so it must never let that lie through: refuse the turn instead of
  # dispatching into an empty directory, and make the failure loud since
  # otherwise it is only visible by grepping the daemon log.
  defp ensure_dispatch_ready(_workspace, _issue_or_identifier, worker_host) when is_binary(worker_host), do: :ok

  defp ensure_dispatch_ready(workspace, issue_or_identifier, nil) do
    case Provisioner.workspace_readiness(workspace) do
      :ready ->
        :ok

      not_ready ->
        reason = {:workspace_provisioning_incomplete, workspace, not_ready}
        emit_provisioning_incomplete_alert(workspace, issue_or_identifier, reason)
        {:error, reason}
    end
  end

  defp emit_provisioning_incomplete_alert(workspace, issue_or_identifier, reason) do
    issue_context = Context.build(issue_or_identifier)
    identifier = issue_context.issue_identifier

    Alerts.emit_custom(
      "ticket.#{identifier}.workspace.provisioning_incomplete",
      "Workspace #{workspace} is not a genuine checkout after provisioning; refusing to dispatch. Reason: #{inspect(reason)}",
      issue: identifier,
      workspace: workspace,
      reason: inspect(reason),
      needs_attention: true,
      severity: "warning"
    )
  end

  @doc false
  @spec ensure_git_metadata_writable(Path.t(), worker_host()) :: :ok | {:error, term()}
  def ensure_git_metadata_writable(workspace, worker_host \\ nil),
    do: GitMetadata.ensure_git_metadata_writable(workspace, worker_host)

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace),
      do: Hooks.run_after_run(workspace, issue_or_identifier, worker_host)

  @doc """
  Per-issue workspace path under `root`, applying the same repo-namespace
  segment `create_for_issue/1` uses. `root` should already be expanded.

  Lets other modules (per-workspace alert logging, the opencode session
  writer) locate an existing workspace without re-deriving the layout — keeping
  them in sync with whatever `create_for_issue/1` produced.
  """
  @spec workspace_path_under(Path.t(), String.t()) :: Path.t()
  def workspace_path_under(root, identifier) when is_binary(root) and is_binary(identifier) do
    Layout.issue_workspace_path(root, Layout.safe_identifier(identifier))
  end
end

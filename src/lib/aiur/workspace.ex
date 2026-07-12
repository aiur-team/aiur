defmodule Aiur.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias Aiur.Workspace.{Context, GitMetadata, Hooks, Layout, Provisioner, Refresh, Remove}

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

    with {:ok, workspace, created?} <-
           Provisioner.ensure_workspace(
             workspace,
             worker_host,
             issue_context.pr_head_ref,
             issue_context.branch_name,
             lifecycle
           ),
         :ok <- Hooks.run_after_create(workspace, issue_context, created?, worker_host),
         :ok <- GitMetadata.ensure_agent_logs_excluded(workspace, worker_host),
         :ok <- Hooks.run_github_preflight(workspace, issue_context, worker_host) do
      Provisioner.maybe_install_agent_skills(workspace, worker_host)
      {:ok, workspace}
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace),
      do: Refresh.run(workspace, issue_or_identifier, worker_host)

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

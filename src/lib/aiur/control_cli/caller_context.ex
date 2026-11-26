defmodule Aiur.ControlCLI.CallerContext do
  @moduledoc """
  Refuses control mutations whose caller sits inside an agent workspace.

  The aiur CLI sends `caller_cwd` (its `pwd -P`) and `caller_agent_workspace_env`
  (`AIUR_AGENT_WORKSPACE`, possibly empty). A local call must send both; the
  daemon then compares them with its own workspace root and live agent
  workspaces, so a worker that unsets `AIUR_AGENT_WORKSPACE` is still refused by
  its working directory.
  """

  alias Aiur.Config
  alias Aiur.Orchestrator.Client
  alias Aiur.PathSafety
  alias Aiur.Workspace.Ownership.Store, as: WorkspaceOwnershipStore

  @keys [:caller_cwd, :caller_agent_workspace_env]

  @doc "The option keys that carry caller evidence."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @spec check(keyword()) :: :ok | {:error, :agent_workspace | :caller_context_missing}
  def check(opts) do
    # A remote caller names its project instead of a directory (its cwd is a path on another machine).
    # Local callers must always send one; the workspace-env check below runs for both.
    cwd = if Process.get(:aiur_control_remote_call, false) and not Keyword.has_key?(opts, :caller_cwd), do: {:ok, ""}, else: caller_evidence(opts, :caller_cwd)

    with {:ok, caller_cwd} <- cwd,
         {:ok, caller_agent_workspace} <- caller_evidence(opts, :caller_agent_workspace_env) do
      workspace_paths = daemon_workspace_paths()

      if agent_workspace?(caller_cwd, workspace_paths) or
           agent_workspace?(caller_agent_workspace, workspace_paths) do
        {:error, :agent_workspace}
      else
        :ok
      end
    end
  end

  defp caller_evidence(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when key == :caller_cwd and is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} when key == :caller_agent_workspace_env and is_binary(value) -> {:ok, value}
      _missing_or_invalid -> {:error, :caller_context_missing}
    end
  end

  defp agent_workspace?("", _workspace_paths), do: false

  defp agent_workspace?(path, workspace_paths) do
    Enum.any?(workspace_paths, fn workspace ->
      match?({:ok, _paths}, PathSafety.contained?(workspace, path))
    end)
  end

  defp daemon_workspace_paths do
    [Config.workspace_root() | live_agent_workspaces()]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp live_agent_workspaces do
    snapshot_workspaces() ++ ownership_workspaces()
  end

  defp snapshot_workspaces do
    case Client.snapshot(Aiur.Orchestrator.server(), 500) do
      %{running: running, retrying: retrying} ->
        Enum.flat_map(running ++ retrying, &workspace_path/1)

      _unavailable ->
        []
    end
  end

  defp ownership_workspaces do
    case WorkspaceOwnershipStore.all() do
      {:ok, receipts} ->
        receipts
        |> Map.values()
        |> Enum.flat_map(fn receipt -> workspace_path(Map.get(receipt, :host_lock, %{})) end)

      {:error, _reason} ->
        []
    end
  end

  defp workspace_path(%{workspace_path: path}) when is_binary(path), do: [path]
  defp workspace_path(%{workspace: path}) when is_binary(path), do: [path]
  defp workspace_path(_entry), do: []
end

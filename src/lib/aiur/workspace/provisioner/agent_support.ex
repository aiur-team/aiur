defmodule Aiur.Workspace.Provisioner.AgentSupport do
  @moduledoc false

  require Logger
  alias Aiur.Config
  alias Aiur.Workspace.Remote

  @spec support_modules(:local | :remote) :: [module()]
  def support_modules(scope) do
    tail = if scope == :local, do: [Aiur.AgentBuildGuard, Aiur.AgentScratch, Aiur.Workspace.AttributionGuard], else: [Aiur.AgentScratch]
    [Aiur.AgentSkills] ++ registered_modules() ++ tail
  end

  defp registered_modules, do: Application.get_env(:aiur, :agent_support_modules, [])

  defp missing_workspace_support(workspace) do
    Enum.flat_map(registered_modules(), fn module ->
      if Code.ensure_loaded?(module) and function_exported?(module, :missing_workspace_support, 1),
        do: module.missing_workspace_support(workspace),
        else: []
    end)
  end

  @doc false
  # Install aiur's bundled agent-operating skills and command guards into a
  # freshly populated workspace. Remote workers receive the portable subset
  # through one idempotent SSH script; build admission is currently local-only.
  @spec maybe_install_agent_support(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  def maybe_install_agent_support(workspace, nil) do
    Enum.reduce_while(support_modules(:local), :ok, fn module, :ok ->
      case module.install(workspace) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def maybe_install_agent_support(workspace, worker_host) when is_binary(worker_host) do
    maybe_install_agent_support(workspace, worker_host, &Remote.run_remote_script/3)
  end

  @doc false
  # The last check before an agent turn starts on a local workspace (#2697).
  # A workspace can be rebuilt after `create_for_issue/3` installed its support
  # tree (before_run reconstruction or stale-leftover recreation), and the agent
  # environment still points PATH, GH_CONFIG_DIR and the quota path into it. A
  # missing piece is repaired with the full local install; if it is still
  # missing, dispatch is refused with the names of the missing pieces.
  @spec ensure_local_agent_support(Path.t()) :: :ok | {:error, term()}
  def ensure_local_agent_support(workspace) when is_binary(workspace) do
    case missing_workspace_support(workspace) do
      [] ->
        :ok

      missing ->
        Logger.warning("Repairing incomplete agent support before dispatch workspace=#{workspace} missing=#{inspect(missing)}")

        case maybe_install_agent_support(workspace, nil) do
          :ok ->
            verify_local_agent_support(workspace)

          {:error, reason} ->
            {:error, {:agent_support_repair_failed, workspace, missing_workspace_support(workspace), reason}}
        end
    end
  end

  defp verify_local_agent_support(workspace) do
    case missing_workspace_support(workspace) do
      [] -> :ok
      missing -> {:error, {:agent_support_incomplete, workspace, missing}}
    end
  end

  @doc false
  @spec maybe_install_agent_support(Path.t(), String.t(), (String.t(), String.t(), pos_integer() -> term())) ::
          :ok | {:error, term()}
  def maybe_install_agent_support(workspace, worker_host, runner)
      when is_binary(workspace) and is_binary(worker_host) and is_function(runner, 3) do
    script = remote_agent_support_script(workspace, worker_host)

    case runner.(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("remote agent support install failed worker_host=#{worker_host} result=#{inspect(result)}")
        {:error, {:remote_agent_support_install_failed, result}}
    end
  end

  @doc false
  @spec repair_agent_github_guard(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  def repair_agent_github_guard(workspace, nil) do
    Enum.reduce_while(registered_modules(), :ok, fn module, :ok ->
      case module.install(workspace) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def repair_agent_github_guard(workspace, worker_host) when is_binary(worker_host) do
    repair_agent_github_guard(workspace, worker_host, &Remote.run_remote_script/3)
  end

  @doc false
  @spec repair_agent_github_guard(Path.t(), String.t(), (String.t(), String.t(), pos_integer() -> term())) ::
          :ok | {:error, term()}
  def repair_agent_github_guard(workspace, worker_host, runner)
      when is_binary(workspace) and is_binary(worker_host) and is_function(runner, 3) do
    case runner.(worker_host, Enum.map_join(registered_modules(), "\n", &remote_install_script(&1, workspace, worker_host)), Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      result -> {:error, {:remote_agent_github_guard_repair_failed, result}}
    end
  end

  # `worker_host` is passed to the modules that accept install options so the
  # host-credential cleanup only ever runs on a genuinely remote install (#2478);
  # the same script executed locally must not touch the operator's own `$HOME`.
  defp remote_agent_support_script(workspace, worker_host) do
    Enum.map_join(support_modules(:remote), "\n", fn module ->
      remote_install_script(module, workspace, worker_host)
    end)
  end

  defp remote_install_script(module, workspace, worker_host) do
    if Code.ensure_loaded?(module) and function_exported?(module, :remote_install_script, 2),
      do: module.remote_install_script(workspace, remote_host: worker_host),
      else: module.remote_install_script(workspace)
  end
end

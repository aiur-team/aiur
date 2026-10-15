defmodule Aiur.Workspace.Provisioner.AgentSupport do
  @moduledoc false

  require Logger
  alias Aiur.{AgentGitHubGuard, Config}
  alias Aiur.Workspace.Remote

  @remote_agent_support_modules [Aiur.AgentSkills, Aiur.AgentGitHubGuard, Aiur.AgentScratch]
  @local_agent_support_modules [Aiur.AgentSkills, Aiur.AgentGitHubGuard, Aiur.AgentBuildGuard, Aiur.AgentScratch, Aiur.Workspace.AttributionGuard]

  @doc false
  # Install aiur's bundled agent-operating skills and command guards into a
  # freshly populated workspace. Remote workers receive the portable subset
  # through one idempotent SSH script; build admission is currently local-only.
  @spec maybe_install_agent_support(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  def maybe_install_agent_support(workspace, nil) do
    Enum.reduce_while(@local_agent_support_modules, :ok, fn module, :ok ->
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
    case AgentGitHubGuard.missing_workspace_support(workspace) do
      [] ->
        :ok

      missing ->
        Logger.warning("Repairing incomplete agent support before dispatch workspace=#{workspace} missing=#{inspect(missing)}")

        case maybe_install_agent_support(workspace, nil) do
          :ok ->
            verify_local_agent_support(workspace)

          {:error, reason} ->
            {:error, {:agent_support_repair_failed, workspace, AgentGitHubGuard.missing_workspace_support(workspace), reason}}
        end
    end
  end

  defp verify_local_agent_support(workspace) do
    case AgentGitHubGuard.missing_workspace_support(workspace) do
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
  def repair_agent_github_guard(workspace, nil), do: Aiur.AgentGitHubGuard.install(workspace)

  def repair_agent_github_guard(workspace, worker_host) when is_binary(worker_host) do
    repair_agent_github_guard(workspace, worker_host, &Remote.run_remote_script/3)
  end

  @doc false
  @spec repair_agent_github_guard(Path.t(), String.t(), (String.t(), String.t(), pos_integer() -> term())) ::
          :ok | {:error, term()}
  def repair_agent_github_guard(workspace, worker_host, runner)
      when is_binary(workspace) and is_binary(worker_host) and is_function(runner, 3) do
    case runner.(worker_host, Aiur.AgentGitHubGuard.remote_install_script(workspace, remote_host: worker_host), Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      result -> {:error, {:remote_agent_github_guard_repair_failed, result}}
    end
  end

  # `worker_host` is passed to the modules that accept install options so the
  # host-credential cleanup only ever runs on a genuinely remote install (#2478);
  # the same script executed locally must not touch the operator's own `$HOME`.
  defp remote_agent_support_script(workspace, worker_host) do
    Enum.map_join(@remote_agent_support_modules, "\n", fn module ->
      # `Code.ensure_loaded?/1` first: on a not-yet-loaded module
      # `function_exported?/3` answers false, which would silently fall back to
      # the arity-1 call and drop the remote credential cleanup rather than
      # failing loudly.
      if Code.ensure_loaded?(module) and function_exported?(module, :remote_install_script, 2) do
        module.remote_install_script(workspace, remote_host: worker_host)
      else
        module.remote_install_script(workspace)
      end
    end)
  end
end

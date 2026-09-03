defmodule Aiur.Init.AgentCli do
  @moduledoc """
  Agent-CLI presence checks and installation for the `aiur init` wizard.
  Verifies that each selected backend's CLI is on PATH and offers to install
  the claude app-server automatically.
  """

  alias Aiur.{CodingAgent, Config}
  alias Aiur.Init.ClaudeAdapter

  @spec check_agent_clis(Aiur.Init.io(), Aiur.Init.deps(), [String.t()]) ::
          :ok | {:error, String.t()}
  def check_agent_clis(io, deps, agents) do
    agents
    |> Enum.filter(&(&1 in CodingAgent.configurable_backends() and not is_nil(agent_executable(&1))))
    |> Enum.reduce_while(:ok, fn kind, :ok ->
      case ensure_agent_cli(io, deps, kind) do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  # Claude's CLI is the `aiur-claude` app-server. Version classification comes
  # before auth or installation so a satisfying or safety-unknown existing
  # install is never replaced. Missing and outdated installs must pass the
  # post-install minimum-version gate before setup can continue.
  defp ensure_agent_cli(io, deps, "claude") do
    case ClaudeAdapter.classify(deps.claude_version.()) do
      {:satisfying, version} ->
        io.puts.("Found aiur-claude #{version} (meets #{ClaudeAdapter.min_version()}); leaving it unchanged.")
        run_auth_check(io, "claude agent", fn -> deps.check_agent_auth.("claude") end)

      :missing ->
        install_claude_then_check(io, deps)

      {:outdated, version} ->
        io.puts.("Updating aiur-claude #{version} to #{ClaudeAdapter.min_version()} or newer…")
        install_claude_then_check(io, deps)

      {:unknown, reason} ->
        {:error,
         "claude agent setup failed: the installed aiur-claude version could not be verified " <>
           "(#{reason}); the existing installation was left unchanged"}
    end
  end

  defp ensure_agent_cli(io, deps, kind) do
    run_auth_check(io, "#{kind} agent", fn -> deps.check_agent_auth.(kind) end)
  end

  defp install_claude_then_check(io, deps) do
    spec = ClaudeAdapter.install_spec(deps.claude_registry_version.())
    io.puts.("Installing claude app-server (#{spec})…")

    case deps.install_claude_app_server.(spec) do
      :ok ->
        verify_installed_claude(io, deps)

      {:error, message} ->
        {:error, "claude agent setup failed: couldn't install aiur-claude (#{message})"}
    end
  end

  defp verify_installed_claude(io, deps) do
    case ClaudeAdapter.classify(deps.claude_version.()) do
      {:satisfying, _version} ->
        run_auth_check(io, "claude agent", fn -> deps.check_agent_auth.("claude") end)

      {:outdated, version} ->
        {:error,
         "claude agent setup failed: installed aiur-claude #{version}, but Aiur requires " <>
           "#{ClaudeAdapter.min_version()} or newer"}

      :missing ->
        {:error, "claude agent setup failed: aiur-claude is still missing after installation"}

      {:unknown, reason} ->
        {:error, "claude agent setup failed: couldn't verify aiur-claude after installation (#{reason})"}
    end
  end

  defp run_auth_check(io, label, check) do
    case check.() do
      :ok ->
        :ok

      {:error, message} ->
        io.puts.("⚠️ #{label}: #{message}")

        if io.confirm.("Retry #{label}?", false) do
          run_auth_check(io, label, check)
        else
          :ok
        end
    end
  end

  @spec check_agent_auth(String.t()) :: :ok | {:error, String.t()}
  def check_agent_auth(kind) do
    case agent_executable(kind) do
      nil ->
        {:error, "no command configured for #{kind}"}

      exe ->
        if System.find_executable(exe) do
          :ok
        else
          {:error, "#{exe} not found on PATH — #{install_hint(kind, exe)}"}
        end
    end
  end

  # Names the exact command that provisions a missing backend so the warning is
  # actionable instead of pointing at a generic "CLI".
  @doc false
  @spec install_hint(String.t(), String.t()) :: String.t()
  def install_hint(kind, exe) do
    get_in(CodingAgent.backends(), [kind, :install_hint]) || "install #{exe} and add it to PATH"
  end

  @doc false
  @spec agent_executable(String.t()) :: String.t() | nil
  def agent_executable(kind) do
    command = Config.backend_config(kind)["command"] || get_in(CodingAgent.backends(), [kind, :default_command])

    case ClaudeAdapter.command_parts(command) do
      [exe | _] -> exe
      _ -> nil
    end
  end
end

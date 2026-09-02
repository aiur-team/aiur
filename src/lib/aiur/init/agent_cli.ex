defmodule Aiur.Init.AgentCli do
  @moduledoc """
  Agent-CLI presence checks and installation for the `aiur init` wizard.
  Verifies that each selected backend's CLI is on PATH and offers to install
  the claude app-server automatically.
  """

  alias Aiur.{CodingAgent, Config}

  # `aiur-claude` 1.1.0 is the first adapter release that serves the engine's
  # `dynamicTools` to the agent (earlier versions silently dropped them on
  # `thread/start`), so anything older starts claude agents with no Aiur
  # coordination tools at all — a silent, confusing failure (ref #728).
  @min_claude_version "1.1.0"
  @claude_release_fallback "github:aiur-team/aiur-claude#v#{@min_claude_version}"

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
    case classify_claude_install(deps.claude_version.()) do
      {:satisfying, version} ->
        io.puts.("Found aiur-claude #{version} (meets #{@min_claude_version}); leaving it unchanged.")
        run_auth_check(io, "claude agent", fn -> deps.check_agent_auth.("claude") end)

      :missing ->
        install_claude_then_check(io, deps)

      {:outdated, version} ->
        io.puts.("Updating aiur-claude #{version} to #{@min_claude_version} or newer…")
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
    spec = claude_install_spec(deps.claude_registry_version.())
    io.puts.("Installing claude app-server (#{spec})…")

    case deps.install_claude_app_server.(spec) do
      :ok ->
        verify_installed_claude(io, deps)

      {:error, message} ->
        {:error, "claude agent setup failed: couldn't install aiur-claude (#{message})"}
    end
  end

  defp verify_installed_claude(io, deps) do
    case classify_claude_install(deps.claude_version.()) do
      {:satisfying, _version} ->
        run_auth_check(io, "claude agent", fn -> deps.check_agent_auth.("claude") end)

      {:outdated, version} ->
        {:error,
         "claude agent setup failed: installed aiur-claude #{version}, but Aiur requires " <>
           "#{@min_claude_version} or newer"}

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

  # Installs the selected claude app-server package spec globally via npm. Isolated
  # behind its own function so `aiur init` can provision the claude backend and
  # tests can mock it. Returns a message on failure so provisioning can stop
  # cleanly instead of crashing when npm is absent or the install errors.
  @spec install_claude_app_server(String.t()) :: :ok | {:error, String.t()}
  def install_claude_app_server(package_spec) do
    case run_npm(["install", "-g", package_spec]) do
      {:ok, _output} -> :ok
      {:error, _message} = error -> error
    end
  end

  @doc false
  @spec claude_registry_version() :: {:ok, String.t()} | {:error, String.t()}
  def claude_registry_version do
    case run_npm(["view", "aiur-claude", "version"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _message} = error -> error
    end
  end

  @doc false
  @spec claude_install_spec({:ok, String.t()} | {:error, String.t()}) :: String.t()
  def claude_install_spec(result) do
    case classify_claude_install(result) do
      {:satisfying, version} -> "aiur-claude@#{version}"
      _ -> @claude_release_fallback
    end
  end

  @doc false
  @spec classify_claude_install(:missing | {:ok, String.t()} | {:error, String.t()}) ::
          :missing
          | {:satisfying, String.t()}
          | {:outdated, String.t()}
          | {:unknown, String.t()}
  def classify_claude_install(:missing), do: :missing

  def classify_claude_install({:ok, version}) do
    case Version.parse(version) do
      {:ok, parsed} ->
        if Version.compare(parsed, @min_claude_version) == :lt,
          do: {:outdated, version},
          else: {:satisfying, version}

      :error ->
        {:unknown, "unparseable version: #{version}"}
    end
  end

  def classify_claude_install({:error, reason}), do: {:unknown, reason}

  @doc false
  @spec min_claude_version() :: String.t()
  def min_claude_version, do: @min_claude_version

  # Reads the installed adapter's version via `aiur-claude --version`. Shells
  # out the way install_claude_app_server/1 does and distinguishes a command
  # absent from PATH from an existing command whose version cannot be read.
  @spec claude_version() :: :missing | {:ok, String.t()} | {:error, String.t()}
  def claude_version do
    with exe when is_binary(exe) <- agent_executable("claude"),
         path when is_binary(path) <- System.find_executable(exe) do
      case System.cmd(path, ["--version"], stderr_to_stdout: true) do
        {output, 0} -> parse_claude_version(output)
        {output, status} -> {:error, "#{exe} --version exited #{status}: #{String.trim(output)}"}
      end
    else
      nil -> :missing
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp run_npm(args) do
    with npm when is_binary(npm) <- System.find_executable("npm") || {:error, "npm not found on PATH"} do
      case System.cmd(npm, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, "npm exited #{status}: #{String.trim(output)}"}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # `--version` output isn't contractual (it may carry a name or build suffix),
  # so pull the first semver-shaped token rather than trusting the whole line.
  defp parse_claude_version(output) do
    case Regex.run(~r/\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?/, output) do
      [version] -> {:ok, version}
      _ -> {:error, "unreadable --version output: #{String.trim(output)}"}
    end
  end

  @doc false
  @spec agent_executable(String.t()) :: String.t() | nil
  def agent_executable(kind) do
    command = Config.backend_config(kind)["command"] || get_in(CodingAgent.backends(), [kind, :default_command])

    case command && String.split(String.trim(command), ~r/\s+/, trim: true) do
      [exe | _] -> exe
      _ -> nil
    end
  end
end

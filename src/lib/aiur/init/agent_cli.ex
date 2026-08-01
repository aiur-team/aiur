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

  @no_tools_warning "claude agents will run without Aiur coordination tools " <>
                      "(aiur_declare_blocker, emit_alert, aiur_subscribe)"

  # 1.1.0 isn't on npm yet; name the git fallback so the hint actually resolves.
  @upgrade_hint "upgrade it with: npm install -g aiur-claude@#{@min_claude_version} " <>
                  "(or npm install -g github:its-everdred/claude-app-server until " <>
                  "#{@min_claude_version} is published)"

  @spec check_agent_clis(Aiur.Init.io(), Aiur.Init.deps(), [String.t()]) :: :ok
  def check_agent_clis(io, deps, agents) do
    agents
    |> Enum.filter(&(&1 in CodingAgent.configurable_backends() and not is_nil(agent_executable(&1))))
    |> Enum.each(&ensure_agent_cli(io, deps, &1))

    :ok
  end

  # Claude's CLI is the `aiur-claude` app-server, published to npm. When it's
  # missing, install it before warning so selecting claude during init yields a
  # working backend with no manual PATH steps. An already-present command skips
  # the install (idempotent); a failed install degrades to a manual-install hint
  # rather than wedging setup.
  defp ensure_agent_cli(io, deps, "claude") do
    case deps.check_agent_auth.("claude") do
      :ok -> warn_on_stale_claude(io, deps)
      {:error, _missing} -> install_claude_then_check(io, deps)
    end
  end

  defp ensure_agent_cli(io, deps, kind) do
    run_auth_check(io, "#{kind} agent", fn -> deps.check_agent_auth.(kind) end)
  end

  defp install_claude_then_check(io, deps) do
    io.puts.("Installing claude app-server (aiur-claude)…")

    case deps.install_claude_app_server.() do
      :ok ->
        run_auth_check(io, "claude agent", fn -> deps.check_agent_auth.("claude") end)
        # A fresh install still warrants the check: npm's `latest` is only new
        # enough once the minimum version is published.
        warn_on_stale_claude(io, deps)

      {:error, message} ->
        io.puts.(
          "⚠️ claude agent: couldn't install aiur-claude (#{message}). " <>
            "Install it manually: npm install -g aiur-claude"
        )

        :ok
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

  # Installs the claude app-server (`aiur-claude`) globally via npm. Isolated
  # behind its own function so `aiur init` can provision the claude backend and
  # tests can mock it. Returns a message on failure so the wizard degrades
  # gracefully instead of crashing when npm is absent or the install errors.
  @spec install_claude_app_server() :: :ok | {:error, String.t()}
  def install_claude_app_server do
    case System.find_executable("npm") do
      nil ->
        {:error, "npm not found on PATH"}

      npm ->
        case System.cmd(npm, ["install", "-g", "aiur-claude"], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, "npm exited #{status}: #{String.trim(output)}"}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # An adapter too old to serve coordination tools is a warning, never a
  # hard stop: init already has a working (if degraded) claude backend, and a
  # version we can't read is not proof of a bad one.
  defp warn_on_stale_claude(io, deps) do
    case check_claude_version(deps.claude_version.()) do
      :ok ->
        :ok

      {:error, message} ->
        io.puts.("⚠️ claude agent: #{message}")

        :ok
    end
  end

  @doc false
  @spec min_claude_version() :: String.t()
  def min_claude_version, do: @min_claude_version

  # Compares a detected adapter version against the minimum. Takes the lookup's
  # result rather than performing it so the shell-out stays injectable, and
  # degrades to a warning — not an error — when the version can't be read or
  # parsed, since a false alarm is cheaper than blocking a fleet.
  @doc false
  @spec check_claude_version({:ok, String.t()} | {:error, String.t()}) :: :ok | {:error, String.t()}
  def check_claude_version({:ok, version}) do
    case Version.parse(version) do
      {:ok, parsed} ->
        if Version.compare(parsed, @min_claude_version) == :lt do
          {:error,
           "aiur-claude #{version} is older than #{@min_claude_version} — " <>
             "#{@no_tools_warning}. #{@upgrade_hint}"}
        else
          :ok
        end

      :error ->
        {:error,
         "couldn't parse the aiur-claude version (#{version}) — if it's older than " <>
           "#{@min_claude_version}, #{@no_tools_warning}. #{@upgrade_hint}"}
    end
  end

  def check_claude_version({:error, reason}) do
    {:error,
     "couldn't check the aiur-claude version (#{reason}) — if it's older than " <>
       "#{@min_claude_version}, #{@no_tools_warning}. #{@upgrade_hint}"}
  end

  # Reads the installed adapter's version via `aiur-claude --version`. Shells
  # out the way install_claude_app_server/0 does and returns a message on every
  # failure path so the caller can warn instead of crashing the wizard.
  @spec claude_version() :: {:ok, String.t()} | {:error, String.t()}
  def claude_version do
    with exe when is_binary(exe) <- agent_executable("claude") || {:error, "no command configured"},
         path when is_binary(path) <- System.find_executable(exe) || {:error, "#{exe} unavailable"} do
      case System.cmd(path, ["--version"], stderr_to_stdout: true) do
        {output, 0} -> parse_claude_version(output)
        {output, status} -> {:error, "#{exe} --version exited #{status}: #{String.trim(output)}"}
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

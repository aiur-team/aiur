defmodule Aiur.Init.AgentCli do
  @moduledoc """
  Agent-CLI presence checks and installation for the `aiur init` wizard.
  Verifies that each selected backend's CLI is on PATH and offers to install
  the claude app-server automatically.
  """

  alias Aiur.Claude.AdapterHealth
  alias Aiur.{CodingAgent, Config}

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
      :ok -> warn_on_stale_claude(io, deps, nil)
      {:error, _missing} -> maybe_install_claude(io, deps)
    end
  end

  defp ensure_agent_cli(io, deps, kind) do
    run_auth_check(io, "#{kind} agent", fn -> deps.check_agent_auth.(kind) end)
  end

  # The install spec is an exact pin, so npm would happily replace a newer
  # adapter with the minimum. Read the installed version before installing and
  # leave a satisfying adapter alone: the wizard must never leave the machine
  # with less capability than it found.
  defp maybe_install_claude(io, deps) do
    case AdapterHealth.version_status(deps.claude_version.()) do
      :capable ->
        io.puts.("claude agent: aiur-claude already satisfies #{AdapterHealth.min_version()}; keeping the installed version.")

        :ok

      _status ->
        install_claude_then_check(io, deps)
    end
  end

  defp install_claude_then_check(io, deps) do
    release_status = deps.claude_release_status.()
    install_spec = AdapterHealth.install_spec(release_status)
    io.puts.("Installing claude app-server (aiur-claude)…")

    case deps.install_claude_app_server.(install_spec) do
      :ok ->
        run_auth_check(io, "claude agent", fn -> deps.check_agent_auth.("claude") end)
        warn_on_stale_claude(io, deps, release_status)

      {:error, message} ->
        # Name the same uninstall-first sequence the warning path prints: a
        # bare `npm install -g` is exactly what fails with ENOTEMPTY on a
        # half-removed global package, which is the install that just failed.
        io.puts.(
          "⚠️ claude agent: couldn't install aiur-claude (#{message}). " <>
            "Install it manually: #{AdapterHealth.install_instruction(release_status)}"
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
  @spec install_claude_app_server(String.t(), keyword()) :: :ok | {:error, String.t()}
  def install_claude_app_server(spec, opts \\ []) when is_binary(spec) do
    cmd_fun = Keyword.get(opts, :cmd_fun, &System.cmd/3)

    case Keyword.get_lazy(opts, :npm_path, fn -> System.find_executable("npm") end) do
      nil -> {:error, "npm not found on PATH"}
      npm -> install_with_uninstall_retry(npm, spec, cmd_fun)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc false
  @spec install_claude_app_server() :: :ok | {:error, String.t()}
  def install_claude_app_server do
    AdapterHealth.release_status()
    |> AdapterHealth.install_spec()
    |> install_claude_app_server()
  end

  # A global install over a half-removed `aiur-claude` fails with ENOTEMPTY,
  # and the documented remedy is to uninstall first. Do that automatically on
  # the retry rather than making the operator discover it from the error — the
  # manual hint stays as the last resort when the retry fails too.
  defp install_with_uninstall_retry(npm, spec, cmd_fun) do
    case npm_run(npm, ["install", "-g", spec], cmd_fun) do
      :ok ->
        :ok

      {:error, install_error} ->
        with :ok <- npm_run(npm, ["uninstall", "-g", AdapterHealth.package()], cmd_fun),
             :ok <- npm_run(npm, ["install", "-g", spec], cmd_fun) do
          :ok
        else
          _retry_error -> {:error, install_error}
        end
    end
  end

  defp npm_run(npm, args, cmd_fun) do
    case cmd_fun.(npm, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "npm exited #{status}: #{String.trim(output)}"}
    end
  end

  # An adapter too old to serve coordination tools is a warning, never a
  # hard stop: init already has a working (if degraded) claude backend, and a
  # version we can't read is not proof of a bad one.
  # `known_release_status` is the registry answer the install path already
  # fetched; a nil means nobody has looked yet. Only a version that needs
  # remediation is worth the round-trip, so the lookup stays inside the
  # non-capable branch.
  defp warn_on_stale_claude(io, deps, known_release_status) do
    version_result = deps.claude_version.()

    case AdapterHealth.version_status(version_result) do
      :capable ->
        :ok

      _status ->
        release_status = known_release_status || deps.claude_release_status.()

        case check_claude_version(version_result, release_status) do
          :ok -> :ok
          {:error, message} -> io.puts.("⚠️ claude agent: #{message}")
        end

        :ok
    end
  end

  @doc false
  @spec min_claude_version() :: String.t()
  def min_claude_version, do: AdapterHealth.min_version()

  # Compares a detected adapter version against the minimum. Takes the lookup's
  # result rather than performing it so the shell-out stays injectable, and
  # degrades to a warning — not an error — when the version can't be read or
  # parsed, since a false alarm is cheaper than blocking a fleet.
  @doc false
  @spec check_claude_version({:ok, String.t()} | {:error, term()}, AdapterHealth.release_status()) ::
          :ok | {:error, String.t()}
  def check_claude_version(version_result, release_status),
    do: AdapterHealth.warning(version_result, release_status)

  @doc false
  @spec check_claude_version({:ok, String.t()} | {:error, term()}) :: :ok | {:error, String.t()}
  def check_claude_version(version_result),
    do: check_claude_version(version_result, {:unknown, :not_checked})

  # Reads the installed adapter's version via `aiur-claude --version`. Shells
  # out the way install_claude_app_server/0 does and returns a message on every
  # failure path so the caller can warn instead of crashing the wizard.
  @spec claude_version() :: {:ok, String.t()} | {:error, atom()}
  def claude_version, do: AdapterHealth.installed_version()

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

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
  @sandbox_docs "https://aiur.team/docs/guide/quick-start#codex-on-linux"
  @sandbox_probe_timeout_ms 10_000
  @sandbox_probe_output_bytes 4_096
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

  defp ensure_agent_cli(io, deps, "codex") do
    case deps.check_agent_auth.("codex") do
      :ok ->
        run_auth_check(io, "codex sandbox", deps.check_codex_sandbox)

      {:error, message} ->
        io.puts.("⚠️ codex agent: #{message}")

        if io.confirm.("Retry codex agent?", false) do
          ensure_agent_cli(io, deps, "codex")
        else
          :ok
        end
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

  @doc false
  @spec check_codex_sandbox() :: :ok | {:error, String.t()}
  def check_codex_sandbox do
    if :os.type() == {:unix, :linux} do
      with exe when is_binary(exe) <- agent_executable("codex") || {:error, "codex command is not configured"},
           path when is_binary(path) <- System.find_executable(exe) || {:error, "#{exe} not found on PATH"} do
        run_codex_sandbox_probe(path)
      end
    else
      :ok
    end
  end

  @doc false
  @spec run_codex_sandbox_probe(Path.t(), non_neg_integer()) :: :ok | {:error, String.t()}
  def run_codex_sandbox_probe(path, timeout_ms \\ @sandbox_probe_timeout_ms) do
    port =
      Port.open({:spawn_executable, String.to_charlist(path)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["sandbox", "--", "/bin/pwd"]
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_codex_sandbox_probe(port, deadline, timeout_ms, "")
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, "could not start Codex sandbox probe: #{Exception.message(error)}. See #{@sandbox_docs}"}
  end

  defp collect_codex_sandbox_probe(port, deadline, timeout_ms, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        buffered = output <> chunk
        kept = min(byte_size(buffered), @sandbox_probe_output_bytes)
        recent_output = binary_part(buffered, byte_size(buffered) - kept, kept)
        collect_codex_sandbox_probe(port, deadline, timeout_ms, recent_output)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        detail = if String.trim(output) == "", do: "no diagnostic output", else: String.trim(output)
        {:error, "codex sandbox -- /bin/pwd exited #{status}: #{detail}. See #{@sandbox_docs}"}
    after
      remaining ->
        close_codex_sandbox_probe(port)
        {:error, "codex sandbox -- /bin/pwd timed out after #{timeout_ms}ms. See #{@sandbox_docs}"}
    end
  end

  defp close_codex_sandbox_probe(port) do
    if Port.info(port), do: Port.close(port)

    receive do
      {^port, _message} -> close_codex_sandbox_probe(port)
    after
      0 -> :ok
    end
  rescue
    ArgumentError -> :ok
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

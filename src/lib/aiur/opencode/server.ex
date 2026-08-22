defmodule Aiur.Opencode.Server do
  @moduledoc false

  use GenServer
  require Logger

  alias Aiur.AgentEnvironment
  alias Aiur.Opencode.{Config, Protocol}

  defstruct [:identifier, :workspace, :port, :host, :base_url, :port_ref, :stdout_buffer, :ready_waiters, :ready?]

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec await_ready(pid(), timeout()) :: {:ok, String.t(), non_neg_integer() | nil} | {:error, term()}
  # opencode's first-time SQLite migration can take longer than 10s on cold machines; 30s budget.
  def await_ready(pid, timeout \\ 30_000), do: GenServer.call(pid, :await_ready, timeout)

  @impl true
  def init(opts) do
    workspace = Map.fetch!(opts, :workspace)
    identifier = Map.fetch!(opts, :identifier)
    host = Map.get(opts, :host, "127.0.0.1")
    # Let opencode pick its own port (it announces `listening on http://host:port` on stdout).
    # Pre-allocating via gen_tcp.listen + close races against opencode's bind in TIME_WAIT.
    command = serve_command(host)

    # Trap exits so terminate/2 always runs and reaps the opencode child. A
    # start_link owner that dies abruptly (an ExUnit test process exiting at
    # the end of its case, a slot worker killed mid-boot) otherwise kills this
    # process via link teardown *before* any on_exit/GenServer.stop reaping
    # runs, orphaning `opencode serve` to outlive the VM (#2340).
    Process.flag(:trap_exit, true)

    # Non-login `-c`: a login shell reloads /etc/profile and drops the mise PATH the BEAM inherited.
    port_ref =
      Port.open({:spawn_executable, System.find_executable("bash") || "/bin/bash"}, port_opts(workspace, command))

    os_pid =
      case Port.info(port_ref, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    Logger.info("opencode_server phase=starting issue_identifier=#{identifier} opencode_pid=#{inspect(os_pid)}")

    # `bash -c` execs into opencode-serve, so this pid IS the serve. Kind
    # :serve reaps AFTER session deletion (delete_all needs a live serve).
    Aiur.ProcessReaper.register(:serve, {:os_pid, os_pid}, comm: "opencode")

    {:ok,
     %__MODULE__{
       identifier: identifier,
       workspace: workspace,
       port: nil,
       host: host,
       base_url: nil,
       port_ref: port_ref,
       stdout_buffer: "",
       ready_waiters: [],
       ready?: false
     }}
  end

  @doc false
  @spec launch_env(Path.t()) :: [{charlist(), charlist() | false}]
  def launch_env(workspace) do
    AgentEnvironment.port_shell_startup_env() ++
      [
        {~c"OPENCODE_CONFIG", false},
        {~c"OPENCODE_CONFIG_CONTENT", false},
        {~c"OPENCODE_CONFIG_DIR", String.to_charlist(workspace)}
      ]
  end

  @doc false
  # Port options for the opencode-serve launch. `:stderr_to_stdout` routes the
  # child's stderr through the port pipe instead of letting it inherit the
  # BEAM's stderr. A child (or a child still winding down during teardown)
  # that inherits the suite's stderr keeps the pipe open after the BEAM exits,
  # so a piped `mix test | cat`/CI capture never sees EOF past the summary.
  # Every other long-lived `Port.open` launch in the app (the codex app-server,
  # model discovery, the GitHub budget probe) already isolates stdio this way;
  # the opencode serve was the backend that missed it (#2340).
  @spec port_opts(Path.t(), String.t()) :: [term()]
  def port_opts(workspace, command) do
    [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      cd: workspace,
      env: launch_env(workspace),
      args: ["-c", command]
    ]
  end

  @impl true
  def handle_call(:await_ready, _from, %{ready?: true} = state) do
    {:reply, {:ok, state.base_url, os_pid(state.port_ref)}, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
  end

  @doc false
  # Build the `bash -c` launch command for opencode-serve. Routes the child
  # through the shared `AgentEnvironment` scrub (the same contract the codex/
  # claude app-server and prewarm use): release launcher vars (ROOTDIR, BINDIR,
  # EMU, PROGNAME when release-owned), distribution/cookie vars, and release
  # PATH entries are removed before `exec`, so the Node child and its tool
  # subprocesses never inherit the release-local OTP (#1520). `Port.open`'s
  # partial `:env` list is merged OVER the inherited environment, so it cannot
  # replace release vars by itself — the command prefix is what scrubs them.
  # `exec: true` keeps `bash -c "<scrub>; exec <serve>"` collapsing into the
  # serve PID, so reaping still targets the opencode process directly.
  @spec serve_command(String.t()) :: String.t()
  def serve_command(host) do
    Protocol.serve_command(0, host, Config.serve_args())
    |> AgentEnvironment.scrub_shell_command(exec: true)
  end

  @impl true
  def handle_info({_port, {:exit_status, status}}, state) do
    reason = {:opencode_exit_status, status}
    Enum.each(state.ready_waiters, &GenServer.reply(&1, {:error, reason}))
    {:stop, {:shutdown, reason}, state}
  end

  def handle_info({port, {:data, data}}, %{port_ref: port} = state) do
    buffer = state.stdout_buffer <> data
    {lines, remainder} = take_complete_lines(buffer)

    Enum.each(lines, fn line ->
      Logger.debug("opencode_server stdout issue_identifier=#{state.identifier} line=#{inspect(line)}")
    end)

    state = %{state | stdout_buffer: remainder}

    case Enum.find_value(lines, &parse_listening_port/1) do
      nil ->
        {:noreply, state}

      port_num when state.ready? ->
        Logger.debug("opencode_server duplicate_listening_line issue_identifier=#{state.identifier} port=#{port_num}")
        {:noreply, state}

      port_num ->
        base_url = "http://#{state.host}:#{port_num}"
        Logger.info("opencode_server phase=ready issue_identifier=#{state.identifier} base_url=#{base_url}")
        Enum.each(state.ready_waiters, &GenServer.reply(&1, {:ok, base_url, os_pid(state.port_ref)}))
        {:noreply, %{state | ready?: true, port: port_num, base_url: base_url, ready_waiters: []}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if is_port(state.port_ref) do
      os_pid =
        case Port.info(state.port_ref, :os_pid) do
          {:os_pid, pid} ->
            Aiur.ProcessReaper.unregister({:os_pid, pid})
            pid

          _ ->
            nil
        end

      # Close the port first while it is definitely open: killing the child
      # below auto-closes the port via the :exit_status path, and closing an
      # already-closed port raises ArgumentError (also possible if the child
      # crashed on its own and the port already auto-closed).
      close_port(state.port_ref)
      reap_opencode_children(os_pid)
    end

    :ok
  end

  # The BEAM can auto-close the port (child exit) before terminate runs on the
  # `{:exit_status, ...}` crash path; closing a closed port raises.
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # `Port.close/1` only closes the file descriptors — Node-based
  # opencode-serve ignores SIGPIPE on stdout, so EOF alone does not
  # terminate it. Without explicit `kill -TERM`, opencode survives as
  # an orphan reparented to init, the next aiur boot finds stale serves
  # bound to dead bridge ports, and `Aiur.Opencode.AttachPool` leadoff
  # times out talking to them.
  #
  # `bash -c "<single command>"` implicitly execs into the command, so
  # the port's `os_pid` IS the opencode-serve PID (not a bash wrapper
  # PID). The BEAM's port spawn also makes it a session/process-group
  # leader (os_pid == pgid), so signalling the group reaches the serve
  # and any Node tool children it spawned. Send SIGTERM, give it a short
  # grace to shut down cleanly (it owns a SQLite DB), then SIGKILL —
  # a fire-and-forget SIGTERM can leave a slow-to-die serve alive long
  # enough to survive the VM exit and hold a pipe open (#2340).
  @terminate_grace_ms 1_000

  defp reap_opencode_children(os_pid) when is_integer(os_pid) and os_pid > 0 do
    reap_process_group(os_pid)
  end

  defp reap_opencode_children(_os_pid), do: :ok

  defp reap_process_group(pid) do
    _ = System.cmd("kill", ["-TERM", "-#{pid}"], stderr_to_stdout: true)

    if wait_for_process_exit(pid, @terminate_grace_ms) do
      :ok
    else
      _ = System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
      :ok
    end
  end

  defp wait_for_process_exit(pid, remaining_ms) when remaining_ms <= 0, do: not process_alive?(pid)

  defp wait_for_process_exit(pid, remaining_ms) do
    if process_alive?(pid) do
      Process.sleep(50)
      wait_for_process_exit(pid, remaining_ms - 50)
    else
      true
    end
  end

  defp process_alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status == 0
  catch
    _, _ -> false
  end

  defp os_pid(port_ref) do
    case Port.info(port_ref, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp take_complete_lines(buffer) do
    case String.split(buffer, "\n") do
      [partial] -> {[], partial}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp parse_listening_port(line) do
    case Regex.run(~r{listening on https?://[^:]+:(\d+)}, line) do
      [_, port_str] -> String.to_integer(port_str)
      _ -> nil
    end
  end
end

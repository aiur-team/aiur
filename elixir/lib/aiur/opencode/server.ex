defmodule Aiur.Opencode.Server do
  @moduledoc false

  use GenServer
  require Logger

  alias Aiur.Opencode.{Config, Protocol}

  defstruct [:identifier, :workspace, :port, :host, :base_url, :port_ref, :stdout_buffer, :ready_waiters, :ready?]

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec await_ready(pid(), timeout()) :: {:ok, String.t(), non_neg_integer() | nil} | {:error, term()}
  # opencode's first-time SQLite migration can take longer than 10s on cold machines; align with PaneSession's 30s budget.
  def await_ready(pid, timeout \\ 30_000), do: GenServer.call(pid, :await_ready, timeout)

  @impl true
  def init(opts) do
    workspace = Map.fetch!(opts, :workspace)
    identifier = Map.fetch!(opts, :identifier)
    host = Map.get(opts, :host, "127.0.0.1")
    # Let opencode pick its own port (it announces `listening on http://host:port` on stdout).
    # Pre-allocating via gen_tcp.listen + close races against opencode's bind in TIME_WAIT.
    command = Protocol.serve_command(0, host, Config.serve_args())

    # Non-login `-c`: a login shell reloads /etc/profile and drops the mise PATH the BEAM inherited.
    port_ref =
      Port.open({:spawn_executable, System.find_executable("bash") || "/bin/bash"}, [
        :binary,
        :exit_status,
        cd: workspace,
        args: ["-c", command]
      ])

    os_pid =
      case Port.info(port_ref, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    Logger.info("opencode_server phase=starting issue_identifier=#{identifier} opencode_pid=#{inspect(os_pid)}")

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

  @impl true
  def handle_call(:await_ready, _from, %{ready?: true} = state) do
    {:reply, {:ok, state.base_url, os_pid(state.port_ref)}, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
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
    if is_port(state.port_ref), do: Port.close(state.port_ref)
    :ok
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

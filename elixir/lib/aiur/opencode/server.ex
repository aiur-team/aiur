defmodule Aiur.Opencode.Server do
  @moduledoc false

  use GenServer
  require Logger

  alias Aiur.Opencode.{ApiClient, Config, Protocol}

  defstruct [:identifier, :workspace, :port, :host, :base_url, :port_ref, :ready_waiters, :ready?]

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec await_ready(pid(), timeout()) :: {:ok, String.t(), non_neg_integer() | nil} | {:error, term()}
  def await_ready(pid, timeout \\ 10_000), do: GenServer.call(pid, :await_ready, timeout)

  @impl true
  def init(opts) do
    workspace = Map.fetch!(opts, :workspace)
    identifier = Map.fetch!(opts, :identifier)
    host = Map.get(opts, :host, "127.0.0.1")
    port = Map.get(opts, :port, :auto)
    port = if port == :auto, do: free_port(), else: port
    base_url = "http://#{host}:#{port}"
    command = Protocol.serve_command(port, host, Config.serve_args())

    port_ref =
      Port.open({:spawn_executable, System.find_executable("bash") || "/bin/bash"}, [
        :binary,
        :exit_status,
        cd: workspace,
        args: ["-lc", command]
      ])

    os_pid =
      case Port.info(port_ref, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    Logger.info("opencode_server phase=starting issue_identifier=#{identifier} opencode_pid=#{inspect(os_pid)} base_url=#{base_url}")
    Process.send_after(self(), :poll_health, 100)

    {:ok,
     %__MODULE__{
       identifier: identifier,
       workspace: workspace,
       port: port,
       host: host,
       base_url: base_url,
       port_ref: port_ref,
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
  def handle_info(:poll_health, state) do
    case ApiClient.health(state.base_url) do
      {:ok, _} ->
        Logger.info("opencode_server phase=ready issue_identifier=#{state.identifier} base_url=#{state.base_url}")
        Enum.each(state.ready_waiters, &GenServer.reply(&1, {:ok, state.base_url, os_pid(state.port_ref)}))
        {:noreply, %{state | ready?: true, ready_waiters: []}}

      {:error, _reason} ->
        Process.send_after(self(), :poll_health, 100)
        {:noreply, state}
    end
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    reason = {:opencode_exit_status, status}
    Enum.each(state.ready_waiters, &GenServer.reply(&1, {:error, reason}))
    {:stop, {:shutdown, reason}, state}
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

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

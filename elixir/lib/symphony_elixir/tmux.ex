defmodule SymphonyElixir.Tmux do
  @moduledoc """
  tmux control-mode client.

  Owns a long-lived `tmux -CC attach` Port and exposes a small synchronous
  command API plus an event subscription. Parsing of the wire format lives
  in `SymphonyElixir.Tmux.Protocol`; this module is the transport and the
  GenServer plumbing.

  Notification events are forwarded to every subscribed pid as
  `{:tmux_event, event}` messages where `event` matches the shape
  documented in `SymphonyElixir.Tmux.Protocol`.

  The GenServer accepts a `:transport` opt for tests:

    * `:port` (default) opens `tmux -CC attach -t <session>` via `Port.open/2`.
    * `{:mock, pid}` skips the Port entirely; tests inject incoming bytes by
      sending `{:tmux_mock_data, chunk}` to the GenServer and capture
      outbound writes from the GenServer to `pid` as `{:tmux_mock_out, line}`.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Tmux.Protocol

  @default_session "symphony"

  @type command_response :: {:ok, [String.t()]} | {:error, [String.t()] | atom()}

  # Public API ----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec command(GenServer.server(), String.t(), timeout()) :: command_response()
  def command(server \\ __MODULE__, command, timeout \\ 5_000) when is_binary(command) do
    GenServer.call(server, {:command, command}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec subscribe_events(GenServer.server()) :: :ok | {:error, term()}
  def subscribe_events(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
  end

  @spec spawn_pane_for(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_pane_for(server \\ __MODULE__, identifier, command_to_run)
      when is_binary(identifier) and is_binary(command_to_run) do
    cmd = ~s(split-window -h -P -F "\#{pane_id}" #{command_to_run})

    case command(server, cmd) do
      {:ok, [pane_id | _]} -> {:ok, String.trim(pane_id)}
      {:ok, []} -> {:error, :no_pane_id}
      {:error, reason} -> {:error, reason}
    end
  end

  # GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, :port)
    session = Keyword.get(opts, :session, @default_session)

    state = %{
      transport: transport,
      session: session,
      port: nil,
      parser: Protocol.new_state(),
      pending: :queue.new(),
      subscribers: MapSet.new()
    }

    case transport do
      :port -> {:ok, open_port(state)}
      {:mock, _pid} -> {:ok, state}
    end
  end

  @impl true
  def handle_call({:command, command}, from, state) do
    write_command(state, command)
    new_pending = :queue.in(from, state.pending)
    {:noreply, %{state | pending: new_pending}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) when is_port(port) do
    {:noreply, process_chunk(state, chunk)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) when is_port(port) do
    Logger.warning("tmux control-mode port exited with status #{status}; reconnecting")
    {:noreply, reopen(state)}
  end

  def handle_info({:tmux_mock_data, chunk}, state) when is_binary(chunk) do
    {:noreply, process_chunk(state, chunk)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Internals -----------------------------------------------------------------

  defp open_port(state) do
    case System.find_executable("tmux") do
      nil ->
        Logger.error("tmux executable not found; control mode unavailable")
        state

      executable ->
        port =
          Port.open(
            {:spawn_executable, executable},
            [:binary, :exit_status, args: ["-CC", "attach", "-t", state.session]]
          )

        %{state | port: port}
    end
  end

  defp reopen(state) do
    state
    |> reply_pending_with({:error, :port_closed})
    |> Map.put(:parser, Protocol.new_state())
    |> Map.put(:port, nil)
    |> open_port()
  end

  defp reply_pending_with(state, response) do
    Enum.each(:queue.to_list(state.pending), &GenServer.reply(&1, response))
    %{state | pending: :queue.new()}
  end

  defp write_command(%{transport: :port, port: port}, command) when is_port(port) do
    Port.command(port, command <> "\n")
  end

  defp write_command(%{transport: {:mock, pid}}, command) do
    send(pid, {:tmux_mock_out, command})
  end

  defp write_command(_state, _command), do: :ok

  defp process_chunk(state, chunk) do
    {parser, events} = Protocol.parse(state.parser, chunk)
    new_state = Enum.reduce(events, %{state | parser: parser}, &dispatch_event/2)
    new_state
  end

  defp dispatch_event({:command_result, _cmd_num, status, body}, state) do
    case :queue.out(state.pending) do
      {{:value, from}, rest} ->
        GenServer.reply(from, response_for(status, body))
        %{state | pending: rest}

      {:empty, _} ->
        state
    end
  end

  defp dispatch_event({:notification, _name, _arg1, _arg2} = event, state) do
    notify_subscribers(state, event)
  end

  defp dispatch_event({:notification, _name, _arg} = event, state) do
    notify_subscribers(state, event)
  end

  defp dispatch_event({:notification, _name} = event, state) do
    notify_subscribers(state, event)
  end

  defp dispatch_event({:unknown_notification, line}, state) do
    Logger.debug("tmux unknown notification: #{line}")
    state
  end

  defp notify_subscribers(state, event) do
    Enum.each(state.subscribers, fn pid -> send(pid, {:tmux_event, event}) end)
    state
  end

  defp response_for(:ok, body), do: {:ok, body}
  defp response_for(:error, body), do: {:error, body}
end

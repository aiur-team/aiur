defmodule SymphonyPane.Conversation do
  @moduledoc """
  GenServer wiring the viewport, composer, and transcript subscription
  for one open conversation pane.

  Owns a linked reader process that consumes stdin in raw mode. Each
  keystroke flows in as a `{:input, byte}` message. PubSub
  `{:transcript_event, ...}` and `{:alert, ...}` messages append to the
  in-memory transcript and trigger a re-render.

  Submit path: the composer is reset locally, the message is forwarded
  to the Symphony node via `:rpc.call` (2 s timeout) so we can surface
  any error to the user. On `:ok`, the symmetric `AgentChat.send`
  broadcast arrives over PubSub and renders the `you: …` echo. On
  `{:error, reason}` (e.g. `:body_too_long`, RPC failure), a
  `:system` transcript event is appended so the message never silently
  vanishes.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentEvents, AgentPubSub, Os}
  alias SymphonyPane.{Composer, Viewport}

  @type opts :: keyword()

  @spec start_link(String.t(), opts()) :: GenServer.on_start()
  def start_link(identifier, opts \\ []) when is_binary(identifier) do
    GenServer.start_link(__MODULE__, {identifier, opts}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init({identifier, opts}) do
    Process.flag(:trap_exit, true)

    symphony_node = Keyword.get(opts, :symphony_node, default_symphony_node())
    write_fun = Keyword.get(opts, :write_fun, &IO.write/1)
    input_fun = Keyword.get(opts, :input_fun, fn -> IO.binread(:stdio, 1) end)
    skip_raw_mode? = Keyword.get(opts, :skip_raw_mode, false)
    {cols, rows} = terminal_geometry()

    Logger.debug("Conversation.init identifier=#{identifier} symphony_node=#{inspect(symphony_node)} cols=#{cols} rows=#{rows}")

    if symphony_node do
      _ = connect_to_symphony(symphony_node)
    end

    case AgentPubSub.subscribe_agent(identifier) do
      :ok -> Logger.debug("Conversation subscribed to agent topic identifier=#{identifier}")
      other -> Logger.warning("Conversation subscribe failed identifier=#{identifier} -> #{inspect(other)}")
    end

    state = %{
      identifier: identifier,
      transcript: [],
      composer: Composer.new(),
      columns: cols,
      rows: rows,
      symphony_node: symphony_node,
      write_fun: write_fun,
      restore?: not skip_raw_mode?,
      reader_pid: nil
    }

    case enter_raw_mode(skip_raw_mode?) do
      :ok ->
        parent = self()
        reader_pid = spawn_link(fn -> read_loop(parent, input_fun) end)
        render(state)
        {:ok, %{state | reader_pid: reader_pid}}

      {:error, reason} ->
        Logger.warning("Conversation pane raw mode failed: #{inspect(reason)}")
        render(state)
        {:ok, state}
    end
  end

  @impl true
  def terminate(_reason, %{restore?: true}) do
    restore_terminal()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_info({:input, "\e"}, state), do: {:noreply, state}
  def handle_info({:input, ""}, state), do: {:noreply, state}

  def handle_info({:input, "\r"}, state), do: handle_submit(state)
  def handle_info({:input, "\n"}, state), do: handle_submit(state)

  def handle_info({:input, "\x7f"}, state) do
    new_state = %{state | composer: Composer.backspace(state.composer)}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:input, byte}, state) when is_binary(byte) do
    new_state = %{state | composer: Composer.append(state.composer, byte)}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:transcript_event, event}, state) do
    Logger.debug("Conversation got transcript_event identifier=#{state.identifier} role=#{inspect(event[:role])} bytes=#{byte_size(event[:body] || "")}")

    new_state = %{state | transcript: state.transcript ++ [event]}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:alert, event}, state) do
    system_line = AgentEvents.transcript_event(:system, "[alert] " <> Map.get(event, :message, ""))
    new_state = %{state | transcript: state.transcript ++ [system_line]}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:nodedown, _node}, state) do
    Logger.warning("Symphony node went down; conversation pane exiting")
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, _reason}, %{reader_pid: pid} = state),
    do: {:noreply, %{state | reader_pid: nil}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  defp handle_submit(state) do
    {new_composer, text} = Composer.submit(state.composer)

    if text == "" do
      new_state = %{state | composer: new_composer}
      render(new_state)
      {:noreply, new_state}
    else
      submit_text(state, new_composer, text)
    end
  end

  defp submit_text(state, new_composer, text) do
    case send_message(state.symphony_node, state.identifier, text) do
      :ok ->
        # Success: the symmetric AgentChat broadcast will arrive over PubSub
        # and append the `you: …` echo. No local optimistic echo here.
        new_state = %{state | composer: new_composer}
        render(new_state)
        {:noreply, new_state}

      {:error, reason} ->
        system = AgentEvents.transcript_event(:system, "send failed: #{inspect(reason)}")
        new_state = %{state | composer: new_composer, transcript: state.transcript ++ [system]}
        render(new_state)
        {:noreply, new_state}
    end
  end

  defp connect_to_symphony(node) when is_atom(node) do
    case Node.connect(node) do
      true ->
        Process.monitor({SymphonyElixir.Distribution, node})
        Node.monitor(node, true)
        :ok

      false ->
        Logger.warning("Conversation pane could not connect to #{inspect(node)}")
        :error

      :ignored ->
        Logger.warning("Conversation pane skipping Node.connect (#{inspect(node)}): local node not distributed")

        :error
    end
  end

  defp send_message(nil, identifier, text) do
    Logger.info("(no node) pane #{identifier}: #{text}")
    :ok
  end

  defp send_message(node, identifier, text) when is_atom(node) do
    Logger.debug("Conversation.send_message rpc.call identifier=#{identifier} node=#{inspect(node)} bytes=#{byte_size(text)}")

    case :rpc.call(node, SymphonyElixir.PaneRPC, :send_operator_message, [identifier, text], 2_000) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Conversation.send_message error identifier=#{identifier} reason=#{inspect(reason)}")

        {:error, reason}

      {:badrpc, reason} ->
        Logger.warning("Conversation.send_message badrpc identifier=#{identifier} reason=#{inspect(reason)}")

        {:error, {:rpc, reason}}
    end
  end

  defp render(state) do
    # Re-query geometry on every render so tmux pane resizes are picked up
    # without us having to wire SIGWINCH (tmux doesn't update COLUMNS/LINES
    # in the child env on resize).
    {cols, rows} = terminal_geometry()

    {frame, {row, col}} =
      Viewport.render(%{
        identifier: state.identifier,
        transcript: state.transcript,
        composer: state.composer,
        columns: cols,
        rows: rows
      })

    cursor_move = "\e[#{row};#{col}H"
    state.write_fun.([frame, cursor_move])
    :ok
  end

  defp read_loop(parent, input_fun) do
    case input_fun.() do
      :eof ->
        :ok

      "" ->
        read_loop(parent, input_fun)

      byte ->
        send(parent, {:input, byte})
        read_loop(parent, input_fun)
    end
  end

  defp enter_raw_mode(true), do: :ok

  defp enter_raw_mode(false) do
    Os.stty(["-icanon", "-echo", "-isig", "-ixon", "min", "0", "time", "1"])
  rescue
    _ -> {:error, :stty_unavailable}
  end

  defp restore_terminal do
    Os.stty(["sane"])
  rescue
    _ -> :ok
  end

  defp terminal_geometry do
    cols =
      case :io.columns() do
        {:ok, c} when is_integer(c) and c > 0 -> c
        _ -> parse_int(System.get_env("COLUMNS"), 80)
      end

    rows =
      case :io.rows() do
        {:ok, r} when is_integer(r) and r > 0 -> r
        _ -> parse_int(System.get_env("LINES"), 24)
      end

    {cols, rows}
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp default_symphony_node do
    case System.get_env("SYMPHONY_NODE") do
      nil -> nil
      "" -> nil
      str -> String.to_atom(str)
    end
  end
end

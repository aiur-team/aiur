defmodule AiurPane.Conversation do
  @moduledoc """
  GenServer wiring the viewport, composer, and transcript subscription
  for one open conversation pane.

  Owns a linked reader process that consumes stdin in raw mode. Each
  keystroke flows in as a `{:input, byte}` message. PubSub
  `{:transcript_event, ...}` and `{:alert, ...}` messages append to the
  in-memory transcript and trigger a re-render.

  Submit path: the composer is reset locally, the message is forwarded
  to the Aiur node via `:rpc.call` (2 s timeout) so we can surface
  any error to the user. On `:ok`, the symmetric `AgentChat.send`
  broadcast arrives over PubSub and renders the `you: …` echo. On
  `{:error, reason}` (e.g. `:body_too_long`, RPC failure), a
  `:system` transcript event is appended so the message never silently
  vanishes.
  """

  use GenServer
  require Logger

  alias Aiur.{AgentEvents, AgentPubSub, Os}
  alias AiurPane.{Composer, Viewport}

  @type opts :: keyword()

  @spec start_link(String.t(), opts()) :: GenServer.on_start()
  def start_link(identifier, opts \\ []) when is_binary(identifier) do
    GenServer.start_link(__MODULE__, {identifier, opts}, name: Keyword.get(opts, :name, __MODULE__))
  end

  # Geometry-watch tick interval. Re-renders the pane when the
  # terminal dimensions change (tmux resizes our pane after a new pane
  # is added to the window). Cheap operation; idempotent when no
  # change is detected.
  @geometry_tick_ms 250

  @impl true
  def init({identifier, opts}) do
    Process.flag(:trap_exit, true)

    aiur_node = Keyword.get(opts, :aiur_node, default_aiur_node())
    write_fun = Keyword.get(opts, :write_fun, &IO.write/1)
    input_fun = Keyword.get(opts, :input_fun, fn -> IO.binread(:stdio, 1) end)
    skip_raw_mode? = Keyword.get(opts, :skip_raw_mode, false)
    {cols, rows} = terminal_geometry()

    Logger.debug("Conversation.init identifier=#{identifier} aiur_node=#{inspect(aiur_node)} cols=#{cols} rows=#{rows}")

    if aiur_node do
      _ = connect_to_aiur(aiur_node)
    end

    case AgentPubSub.subscribe_agent(identifier) do
      :ok -> Logger.debug("Conversation subscribed to agent topic identifier=#{identifier}")
      other -> Logger.warning("Conversation subscribe failed identifier=#{identifier} -> #{inspect(other)}")
    end

    # Also subscribe to the global running-summary stream so the
    # pane's header can reflect this agent's live work_state and
    # title without a separate RPC poll.
    _ = AgentPubSub.subscribe_running()

    {initial_transcript, initial_title} = fetch_initial_transcript(aiur_node, identifier)

    state = %{
      identifier: identifier,
      title: initial_title,
      work_state: :working,
      transcript: initial_transcript,
      composer: Composer.new(),
      columns: cols,
      rows: rows,
      aiur_node: aiur_node,
      write_fun: write_fun,
      restore?: not skip_raw_mode?,
      reader_pid: nil
    }

    schedule_geometry_tick()

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

  defp schedule_geometry_tick do
    Process.send_after(self(), :geometry_tick, @geometry_tick_ms)
  end

  @impl true
  def terminate(_reason, %{restore?: true}) do
    restore_terminal()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  # Bare `\e` arrives when the reader saw an ESC that wasn't followed by
  # a CSI introducer (`[`). The reader filters CSI sequences out of the
  # byte stream and emits semantic `{:input_key, ...}` events instead,
  # so any `{:input, "\e"}` that still reaches us is a lone escape and
  # should be ignored — we don't want it inserted into the buffer.
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

  # Semantic key events emitted by the raw-stdin reader after it has
  # decoded a CSI escape sequence. `:left` / `:right` move the cursor
  # within the composer buffer; `:up` / `:down` are reserved for future
  # history navigation and currently no-op so an accidental arrow key
  # doesn't corrupt the buffer.
  def handle_info({:input_key, :left}, state) do
    new_state = %{state | composer: Composer.move_left(state.composer)}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:input_key, :right}, state) do
    new_state = %{state | composer: Composer.move_right(state.composer)}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:input_key, _other}, state), do: {:noreply, state}

  def handle_info({:transcript_event, event}, state) do
    Logger.debug("Conversation got transcript_event identifier=#{state.identifier} role=#{inspect(event[:role])} bytes=#{byte_size(event[:body] || "")}")

    new_state = %{state | transcript: state.transcript ++ [event]}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:alert, event}, state) do
    # The pane renders just the alert message body — the structured
    # name (e.g. "task.todo") is interesting to logs and tooling but
    # noise to a reader scanning the chat scroll, where the colored
    # `alert` tag already tells you the line is an alert. The per-issue
    # file log (`Aiur.IssueLog`) still records the structured
    # name + message via the original alert event for tail-able context.
    body = to_string(Map.get(event, :message, ""))
    alert_line = AgentEvents.transcript_event(:alert, body)
    new_state = %{state | transcript: state.transcript ++ [alert_line]}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:running_changed, summaries}, state) do
    # Find this issue's summary in the broadcast and pull out
    # `work_state` + `title` so the header reflects the live state.
    # When the agent isn't in the running set (just finished), keep
    # whatever we last knew — the header should not flicker to
    # `:working` and back.
    case Enum.find(summaries, fn s -> Map.get(s, :identifier) == state.identifier end) do
      nil ->
        {:noreply, state}

      summary ->
        new_work_state = Map.get(summary, :work_state, state.work_state)
        new_title = Map.get(summary, :title) || state.title

        if new_work_state == state.work_state and new_title == state.title do
          {:noreply, state}
        else
          new_state = %{state | work_state: new_work_state, title: new_title}
          render(new_state)
          {:noreply, new_state}
        end
    end
  end

  def handle_info(:geometry_tick, state) do
    # tmux resizes the pane when another pane is added or removed from
    # the window; the existing rendered frame is sized for the old
    # geometry until something forces a re-render. Poll the current
    # geometry on a short interval and re-render when it changes so
    # the layout reflows immediately, without waiting for the user to
    # type a key.
    {cols, rows} = terminal_geometry()
    schedule_geometry_tick()

    if cols == state.columns and rows == state.rows do
      {:noreply, state}
    else
      new_state = %{state | columns: cols, rows: rows}
      render(new_state)
      {:noreply, new_state}
    end
  end

  def handle_info({:nodedown, _node}, state) do
    Logger.warning("Aiur node went down; conversation pane exiting")
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
    case send_message(state.aiur_node, state.identifier, text) do
      :ok ->
        # Success: the symmetric AgentChat broadcast will arrive over PubSub
        # and append the `you: …` echo. No local optimistic echo here.
        new_state = %{state | composer: new_composer}
        render(new_state)
        {:noreply, new_state}

      {:error, reason} ->
        system = AgentEvents.transcript_event(:system, send_error_message(reason))
        new_state = %{state | composer: new_composer, transcript: state.transcript ++ [system]}
        render(new_state)
        {:noreply, new_state}
    end
  end

  defp send_error_message(:max_concurrent_agents_reached),
    do:
      "Agent is paused and no slots are free — pause another agent or raise the cap (←/→ from the agent list)."

  defp send_error_message(:no_running_agent),
    do: "Agent is not running — start it from the agent list (space) first."

  defp send_error_message(reason), do: "send failed: #{inspect(reason)}"

  defp connect_to_aiur(node) when is_atom(node) do
    case Node.connect(node) do
      true ->
        Process.monitor({Aiur.Distribution, node})
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

    case :rpc.call(node, Aiur.PaneRPC, :send_operator_message, [identifier, text], 2_000) do
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
        title: Map.get(state, :title),
        work_state: Map.get(state, :work_state, :working),
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

      "\e" ->
        # Possible CSI escape sequence: `\e[<params><final>`. Peek the
        # next byte to decide. If it isn't `[`, treat as a bare ESC and
        # drop both bytes (terminal apps generally ignore unknown ESC
        # sequences and we don't want them landing in the buffer).
        case input_fun.() do
          :eof -> :ok
          "[" -> read_csi(parent, input_fun, "")
          _other -> read_loop(parent, input_fun)
        end

      byte ->
        send(parent, {:input, byte})
        read_loop(parent, input_fun)
    end
  end

  defp read_csi(parent, input_fun, params) do
    case input_fun.() do
      :eof ->
        :ok

      byte ->
        if csi_final?(byte) do
          dispatch_csi(parent, params, byte)
          read_loop(parent, input_fun)
        else
          read_csi(parent, input_fun, params <> byte)
        end
    end
  end

  # CSI sequences terminate on the first byte in `@<final>~` ranges; we
  # only care about the alphabetic finals used by arrow keys (A/B/C/D).
  defp csi_final?(<<c>>) when c in ?A..?Z or c in ?a..?z or c == ?~, do: true
  defp csi_final?(_byte), do: false

  defp dispatch_csi(parent, "", "A"), do: send(parent, {:input_key, :up})
  defp dispatch_csi(parent, "", "B"), do: send(parent, {:input_key, :down})
  defp dispatch_csi(parent, "", "C"), do: send(parent, {:input_key, :right})
  defp dispatch_csi(parent, "", "D"), do: send(parent, {:input_key, :left})
  defp dispatch_csi(_parent, _params, _final), do: :ok

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

  defp fetch_initial_transcript(nil, _identifier), do: {[], nil}

  defp fetch_initial_transcript(node, identifier) when is_atom(node) do
    case :rpc.call(node, Aiur.PaneRPC, :fetch_context, [identifier, 50], 2_000) do
      {:ok, %{context_message: context_message, history: history} = result} ->
        history_events = Enum.map(history, &normalize_history_entry/1)

        events =
          case context_message do
            nil -> history_events
            msg -> [AgentEvents.transcript_event(:system, msg) | history_events]
          end

        # The context map may also expose the ticket title directly so
        # the pane header can render it without re-parsing the
        # `Working on …` system message. Fall back to extracting from
        # the system message when an older `fetch_context` shape
        # doesn't include `:title`.
        title = Map.get(result, :title) || extract_title_from_context(context_message)
        {events, title}

      {:badrpc, reason} ->
        Logger.warning("Conversation.fetch_initial_transcript badrpc identifier=#{identifier} reason=#{inspect(reason)}")

        {[], nil}

      other ->
        Logger.warning("Conversation.fetch_initial_transcript unexpected identifier=#{identifier} result=#{inspect(other)}")

        {[], nil}
    end
  end

  # `IssueContext.to_message/1` builds a string like
  # `Working on MT-25: Ticket title\n  https://…\n  labels: …\n\n…`.
  # Extract just the title portion (after `: `) so the header can show
  # it without exposing the URL block.
  defp extract_title_from_context(nil), do: nil
  defp extract_title_from_context(""), do: nil

  defp extract_title_from_context(text) when is_binary(text) do
    first_line = text |> String.split(~r/\r?\n/, parts: 2) |> List.first()

    case String.split(first_line, ": ", parts: 2) do
      [_prefix, title] when is_binary(title) and title != "" -> title
      _ -> nil
    end
  end

  defp normalize_history_entry({:transcript_event, event}), do: event

  defp normalize_history_entry({:alert, %{message: message}}) do
    AgentEvents.transcript_event(:alert, to_string(message))
  end

  defp normalize_history_entry(_other), do: AgentEvents.transcript_event(:system, "")

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp default_aiur_node do
    case System.get_env("AIUR_NODE") do
      nil -> nil
      "" -> nil
      str -> String.to_atom(str)
    end
  end
end

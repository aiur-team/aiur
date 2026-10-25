defmodule AiurWeb.StreamdeckLive.Modes do
  @moduledoc """
  Mode transitions for the Stream Deck emulator: grid to command row to logs,
  settings or Commands and back, the Commands page's selection and paging, and
  the pause/resume control calls. Socket in, socket out; the write gate
  (`dashboard_writable?`) stays with the event handlers in `StreamdeckLive`.
  """

  import Phoenix.Component, only: [assign: 3]
  import AiurWeb.StreamdeckLive.Env, only: [endpoint_config: 1, safe_call: 2]
  import AiurWeb.StreamdeckLive.Grid, only: [assign_grid: 5, focus_logs: 3, refresh_knobs: 1, refresh_pager: 1]

  alias Aiur.AgentChat
  alias AiurWeb.StreamdeckCommands
  alias Phoenix.LiveView.Socket

  @spec select_agent_from_params(Socket.t(), map()) :: Socket.t()
  def select_agent_from_params(socket, %{"identifier" => identifier}) when is_binary(identifier) do
    case Enum.find(socket.assigns.grid.agents, &(to_string(&1.identifier) == identifier)) do
      nil ->
        socket

      agent ->
        previous_identifier = socket.assigns.selected_identifier

        socket
        |> assign(:selected_identifier, identifier)
        |> maybe_assign_active(agent)
        |> focus_logs(previous_identifier, identifier)
    end
  end

  def select_agent_from_params(socket, _params), do: socket

  defp maybe_assign_active(%{assigns: %{sd_mode: :grid}} = socket, _agent), do: socket
  defp maybe_assign_active(socket, agent), do: socket |> assign(:sd_active, agent) |> refresh_pager()

  @spec enter_cmd(Socket.t(), map()) :: Socket.t()
  def enter_cmd(socket, %{"identifier" => identifier}) when socket.assigns.sd_mode == :grid do
    case Enum.find(socket.assigns.grid.agents, &(to_string(&1.identifier) == identifier)) do
      nil -> socket
      agent -> socket |> assign(:sd_mode, :cmd) |> assign(:sd_active, agent) |> refresh_pager() |> refresh_knobs()
    end
  end

  def enter_cmd(socket, _params), do: socket

  @spec enter_logs(Socket.t()) :: Socket.t()
  def enter_logs(%{assigns: %{sd_mode: :cmd, sd_active: active}} = socket) when not is_nil(active),
    do: socket |> assign(:sd_mode, :logs) |> refresh_knobs()

  def enter_logs(socket), do: socket

  @spec enter_settings(Socket.t()) :: Socket.t()
  def enter_settings(%{assigns: %{sd_mode: :cmd, sd_active: active}} = socket) when not is_nil(active),
    do: socket |> assign(:sd_mode, :settings) |> refresh_knobs()

  def enter_settings(socket), do: socket

  @spec enter_commands(Socket.t()) :: Socket.t()
  def enter_commands(%{assigns: %{sd_mode: :cmd, sd_active: active}} = socket) when not is_nil(active) do
    identifier = to_string(active.identifier)

    socket
    |> assign(:sd_mode, :commands)
    |> assign(:commands, load_commands(identifier))
    |> assign(:commands_view, :history)
    |> assign(:commands_selection, nil)
    |> assign(:commands_option, nil)
    |> assign(:commands_offset, 0)
    |> assign(:commands_cursor, nil)
    |> assign(:commands_page_index, 0)
    |> assign(:commands_error, nil)
    |> refresh_knobs()
  end

  def enter_commands(socket), do: socket

  # The Commands page is history-first: pressing a history key opens one
  # Command's detail (answering an open one, read-only for a completed one), and
  # pressing an option key on the detail view selects it for reading. Selecting
  # never commits; approving is the deliberate second action on the physical
  # deck, which the browser emulator cannot hold a microphone for.
  @spec select_command(Socket.t(), integer()) :: Socket.t()
  def select_command(%{assigns: %{sd_mode: :commands, commands_view: :history}} = socket, index) do
    case Enum.at(socket.assigns.commands["items"] || [], index) do
      nil ->
        socket

      command ->
        socket
        |> assign(:commands_view, :detail)
        |> assign(:commands_selection, command)
        |> assign(:commands_option, nil)
        |> assign(:commands_offset, 0)
        |> assign(:commands_error, nil)
    end
  end

  def select_command(
        %{assigns: %{sd_mode: :commands, commands_view: :detail, commands_selection: command}} = socket,
        index
      )
      when is_map(command) do
    if index < length(command["options"] || []) do
      assign(socket, :commands_option, index)
    else
      socket
    end
  end

  def select_command(socket, _index), do: socket

  # Dial D pages the Commands page: the option window on the detail view
  # (wrapping), or the history window forward through the opaque server cursor.
  @spec page_commands(Socket.t()) :: Socket.t()
  def page_commands(%{assigns: %{sd_mode: :commands, commands_view: :detail, commands_selection: command}} = socket)
      when is_map(command) do
    count = length(command["options"] || [])
    offset = socket.assigns.commands_offset || 0
    next = if offset + 4 < count, do: offset + 4, else: 0

    socket
    |> assign(:commands_offset, next)
    |> assign(:commands_option, nil)
  end

  def page_commands(%{assigns: %{sd_mode: :commands, commands_view: :history, sd_active: active}} = socket) do
    case socket.assigns.commands do
      %{"has_next" => true, "next_cursor" => cursor} when is_binary(cursor) and cursor != "" ->
        identifier = to_string(active.identifier)

        case commands_page(identifier, cursor) do
          {:ok, next_page} ->
            socket
            |> assign(:commands, next_page)
            |> assign(:commands_cursor, cursor)
            |> assign(:commands_page_index, socket.assigns.commands_page_index + 1)

          {:error, _reason} ->
            assign(socket, :commands_error, "Commands page failed")
        end

      _page ->
        socket
    end
  end

  def page_commands(socket), do: socket

  @spec back(Socket.t()) :: Socket.t()
  def back(%{assigns: %{sd_mode: mode}} = socket) when mode in [:logs, :settings, :commands],
    do: socket |> assign(:sd_mode, :cmd) |> refresh_knobs()

  def back(%{assigns: %{sd_mode: :cmd}} = socket) do
    previous_identifier = socket.assigns.selected_identifier

    socket
    |> assign(:sd_mode, :grid)
    |> assign(:sd_active, nil)
    |> assign_grid(socket.assigns.grid, socket.assigns.grid_column_offset, nil, socket.assigns.grid_dial_value)
    |> focus_logs(previous_identifier, socket.assigns.selected_identifier)
  end

  def back(socket), do: socket

  # The focused agent's Command history for the emulator's Commands surface. A
  # `streamdeck_commands_fun` seam exists only for tests, mirroring
  # `streamdeck_logs_fun`; the production path reads the retained decision store
  # through the same projection the physical channel uses.
  defp load_commands(identifier) do
    case commands_page(identifier, nil) do
      {:ok, page} -> page
      {:error, _reason} -> %{"items" => [], "unavailable" => true}
    end
  end

  defp commands_page(identifier, cursor) do
    case endpoint_config(:streamdeck_commands_fun) do
      fun when is_function(fun, 2) -> safe_call(fn -> fun.(identifier, cursor) end, {:error, :unavailable})
      fun when is_function(fun, 1) -> safe_call(fn -> {:ok, fun.(identifier)} end, {:error, :unavailable})
      _ -> safe_call(fn -> StreamdeckCommands.history(identifier, cursor) end, {:error, :unavailable})
    end
  end

  @spec invoke_command(Socket.t(), String.t()) :: Socket.t()
  def invoke_command(socket, command) do
    case socket.assigns.sd_active do
      %{identifier: identifier} = agent when not is_nil(identifier) ->
        # A control command changes one agent's state, and the orchestrator
        # broadcasts the settled state on the fleet/status topics this view is
        # already subscribed to. Re-reading the whole fleet snapshot here would
        # make the button press block on a `dashboard_snapshot` read (the same
        # cost `refresh_meters/1` avoids for meter observations), so the press
        # only issues the control call and leaves the refresh to the topic.
        invoke_agent_control(socket, to_string(identifier), control_action_for(command, agent))

      _agent ->
        assign(socket, :control_feedback, "No agent selected")
    end
  end

  # Each control key is a single toggle, and the direction is resolved from the
  # state the orchestrator reports rather than from the label the client
  # happened to be rendering. A stale key still reading "Pause" therefore cannot
  # re-pause an agent the orchestrator has already paused.
  defp control_action_for("pause", %{bucket: :paused}), do: :resume
  defp control_action_for("pause", _agent), do: :pause

  defp invoke_agent_control(socket, identifier, :pause) do
    case safe_control_call(fn -> pause_agent(identifier) end) do
      {:ok, _request_id} ->
        assign(socket, :control_feedback, "Pause requested for ##{identifier}")

      {:error, reason} ->
        assign(socket, :control_feedback, "Pause failed: #{inspect(reason)}")
    end
  end

  defp invoke_agent_control(socket, identifier, :resume) do
    case safe_control_call(fn -> resume_agent(identifier) end) do
      {:ok, _result} -> assign(socket, :control_feedback, "Resume requested for ##{identifier}")
      {:error, reason} -> assign(socket, :control_feedback, "Resume failed: #{inspect(reason)}")
    end
  end

  @spec handle_key_press(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_key_press(%{"identifier" => identifier}, socket) when is_binary(identifier) do
    case Enum.find(socket.assigns.grid.agents, &(to_string(&1.identifier) == identifier)) do
      %{bucket: bucket} when bucket in [:running, :paused] ->
        action = if bucket == :running, do: :pause, else: :resume
        {:noreply, invoke_agent_control(socket, identifier, action)}

      _agent ->
        {:noreply, socket}
    end
  end

  def handle_key_press(_params, socket), do: {:noreply, socket}

  defp pause_agent(identifier) do
    case endpoint_config(:agent_chat_pause_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.pause(identifier)
    end
  end

  defp resume_agent(identifier) do
    case endpoint_config(:agent_chat_resume_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.resume(identifier)
    end
  end

  defp safe_control_call(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end
end

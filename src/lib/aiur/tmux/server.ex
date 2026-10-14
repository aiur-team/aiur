defmodule Aiur.Tmux.Server do
  @moduledoc """
  GenServer callbacks behind `Aiur.Tmux`.

  `Aiur.Tmux.start_link/1` starts this module under the caller's `:name`, so
  the registered process name stays `Aiur.Tmux`.
  """

  use GenServer

  alias Aiur.Tmux.{Exec, Input, Layout, Query, Style}

  @default_session_env "AIUR_TMUX_SESSION"
  @default_session_fallback "aiur"

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, :shell)
    session = Keyword.get(opts, :session, default_session())

    state = %{
      transport: transport,
      session: session,
      subscribers: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:command, cmd}, _from, state) do
    {:reply, Exec.run_command(state, cmd), state}
  end

  def handle_call({:set_pane_border, pane_id, text}, _from, state) do
    {:reply, Style.set_pane_border(state, pane_id, text), state}
  end

  def handle_call({:split_pane, target_pane, direction, percent, command_to_run, silent?}, _from, state) do
    {:reply, Layout.split_pane(state, target_pane, direction, percent, command_to_run, silent?), state}
  end

  def handle_call(:resolve_self_pane, _from, state) do
    {:reply, Query.resolve_self_pane(state), state}
  end

  def handle_call({:select_layout, window_target, layout_string}, _from, state) do
    {:reply, Layout.select_layout(state, window_target, layout_string), state}
  end

  def handle_call({:window_size, pane_id}, _from, state) do
    {:reply, Query.window_size(state, pane_id), state}
  end

  def handle_call({:window_for, pane_id}, _from, state) do
    {:reply, Query.window_for(state, pane_id), state}
  end

  def handle_call(:list_windows, _from, state) do
    {:reply, Query.list_windows(state), state}
  end

  def handle_call({:list_panes, window_target}, _from, state) do
    {:reply, Query.list_panes(state, window_target), state}
  end

  def handle_call({:respawn_pane, pane_id, command_to_run}, _from, state) do
    {:reply, Layout.respawn_pane(state, pane_id, command_to_run), state}
  end

  def handle_call({:send_keys_literal, pane_id, text}, _from, state) do
    {:reply, Input.send_keys_literal(state, pane_id, text), state}
  end

  def handle_call({:paste_text, pane_id, text}, _from, state) do
    {:reply, Input.paste_text(state, pane_id, text), state}
  end

  def handle_call({:send_enter, pane_id}, _from, state) do
    {:reply, Input.send_enter(state, pane_id), state}
  end

  def handle_call({:clear_input, pane_id}, _from, state) do
    {:reply, Input.clear_input(state, pane_id), state}
  end

  def handle_call({:send_interrupt, pane_id}, _from, state) do
    {:reply, Input.send_interrupt(state, pane_id), state}
  end

  def handle_call({:send_escape, pane_id}, _from, state) do
    {:reply, Input.send_escape(state, pane_id), state}
  end

  def handle_call({:capture_pane, pane_id}, _from, state) do
    {:reply, Query.capture_pane(state, pane_id), state}
  end

  def handle_call({:pane_pid, pane_id}, _from, state) do
    {:reply, Query.pane_pid(state, pane_id), state}
  end

  def handle_call({:kill_pane, pane_id}, _from, state) do
    {:reply, Layout.kill_pane(state, pane_id), state}
  end

  def handle_call({:new_hidden_window, window_name, command_to_run}, _from, state) do
    {:reply, Layout.new_hidden_window(state, window_name, command_to_run), state}
  end

  def handle_call({:new_hidden_window_with_env, window_name, command_to_run, env}, _from, state) do
    {:reply, Layout.new_hidden_window_with_env(state, window_name, command_to_run, env), state}
  end

  def handle_call({:join_pane, source_pane, target_window}, _from, state) do
    {:reply, Layout.join_pane(state, source_pane, target_window), state}
  end

  def handle_call({:move_pane_hidden, source_pane, target_window}, _from, state) do
    {:reply, Layout.move_pane_hidden(state, source_pane, target_window), state}
  end

  def handle_call({:move_pane_visible, source_pane, target_window}, _from, state) do
    {:reply, Layout.move_pane_visible(state, source_pane, target_window), state}
  end

  def handle_call({:set_pane_title, pane_id, title}, _from, state) do
    {:reply, Style.set_pane_title(state, pane_id, title), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call(:session, _from, state), do: {:reply, state.session, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info({:tmux_mock_data, _chunk}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  defp default_session do
    case System.get_env(@default_session_env) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_session_fallback
    end
  end
end

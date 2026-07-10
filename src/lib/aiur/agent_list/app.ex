defmodule Aiur.AgentList.App do
  @moduledoc """
  Agent-list pane orchestrator.
  """

  use GenServer
  require Logger

  alias Aiur.AgentList.{
    Activation,
    Controls,
    EventIntake,
    PerfIntake,
    RcPaneBorders,
    Renderer,
    RenderState,
    Roster,
    Selection,
    State,
    WarmthIntake
  }

  alias Aiur.{AgentPubSub, PaneManager}
  alias Aiur.Events.DebugLog
  alias Aiur.Opencode.{AttachPool, Slot}

  @dialyzer {:no_return, init: 1, render: 1}
  @dialyzer {:nowarn_function, render: 1}
  @refresh_tick_ms 1_000
  @geometry_tick_ms 250

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec select_previous(GenServer.server()) :: :ok
  def select_previous(server \\ __MODULE__), do: GenServer.cast(server, :select_previous)

  @spec select_next(GenServer.server()) :: :ok
  def select_next(server \\ __MODULE__), do: GenServer.cast(server, :select_next)

  @spec activate(GenServer.server()) :: :ok
  def activate(server \\ __MODULE__), do: GenServer.cast(server, :activate)

  @doc """
  Open the currently-selected agent in a new chat pane (Shift+Enter
  semantics). Distinct from `activate/1`, which swaps the session
  in the last-used pane.
  """
  @spec activate_new_pane(GenServer.server()) :: :ok
  def activate_new_pane(server \\ __MODULE__), do: GenServer.cast(server, :activate_new_pane)

  @doc """
  Attach the currently-selected agent to the most-recently-focused chat
  pane (the same slot rebuilds with the new identifier). When no pane
  is currently focused, falls through to `activate/1` (open in a new
  slot). Triggered by the `a` keybind in `input.ex`.
  """
  @spec attach_selected(GenServer.server()) :: :ok
  def attach_selected(server \\ __MODULE__), do: GenServer.cast(server, :attach_selected)

  @spec toggle_pause(GenServer.server()) :: :ok
  def toggle_pause(server \\ __MODULE__), do: GenServer.cast(server, :toggle_pause)

  @spec toggle_remote_control(GenServer.server()) :: :ok
  def toggle_remote_control(server \\ __MODULE__), do: GenServer.cast(server, :toggle_remote_control)

  @spec adjust_max_concurrent_agents(integer()) :: :ok
  @spec adjust_max_concurrent_agents(GenServer.server(), integer()) :: :ok
  def adjust_max_concurrent_agents(server \\ __MODULE__, delta) when is_integer(delta),
    do: GenServer.cast(server, {:adjust_max_concurrent_agents, delta})

  @spec quit() :: no_return()
  @spec quit(GenServer.server()) :: no_return()
  def quit(_server \\ __MODULE__) do
    # q is a global "shut aiur down" keybind, equivalent to Ctrl-C.
    Logger.info("[user-action] quit source=agent_list")
    Aiur.Shutdown.shutdown(0)
  end

  @spec toggle_help(GenServer.server()) :: :ok
  def toggle_help(server \\ __MODULE__), do: GenServer.cast(server, :toggle_help)

  @spec toggle_layout_orientation(GenServer.server()) :: :ok
  def toggle_layout_orientation(server \\ __MODULE__), do: GenServer.cast(server, :toggle_layout_orientation)

  @spec snapshot(GenServer.server()) :: State.t()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc false
  @spec rc_border_changes(%{optional(String.t()) => String.t()}, [map()], map()) ::
          {[{String.t(), String.t() | nil}], map()}
  def rc_border_changes(open_panes, summaries, applied),
    do: RcPaneBorders.changes(open_panes, summaries, applied)

  @impl true
  def init(opts) do
    Logger.info("aiur_agent_list phase=init os_pid=#{System.pid()}")
    opts = Keyword.put_new(opts, :command_template, Activation.default_command_template())
    state = State.new(opts)

    if Keyword.get(opts, :subscribe?, true), do: subscribe(state.debug_mode?)
    schedule_refresh_tick()
    schedule_geometry_tick()
    render(state)
    elapsed = Aiur.Boot.elapsed_ms()
    Logger.info("aiur_agent_list phase=ready elapsed_ms=#{elapsed} agents=#{length(state.summaries)}")
    Aiur.Perf.event(:agent_list_ready, wall_ms: elapsed)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:select_previous, state), do: select(state, -1)
  def handle_cast(:select_next, state), do: select(state, 1)

  def handle_cast(:activate, state) do
    if state.selection_focus == :agents, do: Activation.activate_selected(state, :new_pane)
    {:noreply, state}
  end

  def handle_cast(:activate_new_pane, state), do: handle_cast(:activate, state)

  def handle_cast(:attach_selected, state) do
    if state.selection_focus == :agents, do: Activation.attach_selected(state)
    {:noreply, state}
  end

  def handle_cast(:toggle_pause, state), do: apply_controls(state, &Controls.toggle_pause/1)
  def handle_cast(:toggle_remote_control, state), do: apply_controls(state, &Controls.toggle_remote_control/1)

  def handle_cast({:adjust_max_concurrent_agents, delta}, state),
    do: apply_controls(state, &Controls.adjust_max_concurrent_agents(&1, delta))

  def handle_cast(:toggle_help, state) do
    state = %{state | help_visible?: not Map.get(state, :help_visible?, false)}
    render(state)
    {:noreply, state}
  end

  def handle_cast(:toggle_layout_orientation, state) do
    case safe_call(fn -> PaneManager.toggle_orientation(state.pane_manager) end) do
      {:ok, orientation} -> Logger.info("[user-action] toggle_layout orientation=#{orientation} source=agent_list")
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:prewarm_phase, phase}, state) do
    state =
      if phase in [:cloning, :fetching, :building],
        do: %{state | prewarm_active?: true, prewarm_phase: phase},
        else: %{state | prewarm_active?: false, prewarm_phase: nil}

    render(state)
    {:noreply, state}
  end

  def handle_info({:running_changed, summaries}, state) do
    {state, slot_ids, retain_ids} = Roster.fold(state, summaries)
    safely_seed_attach_pool(slot_ids, retain_ids)
    state = RcPaneBorders.reconcile(state)
    render(state)
    {:noreply, state}
  end

  def handle_info({:agent_chat_active, identifier} = event, state) when is_binary(identifier), do: apply_warmth(state, event)

  def handle_info({:status_changed, %{status: status}} = event, state) when status in [:pane_opened, :pane_closed] do
    {state, _} = WarmthIntake.fold(state, event)
    state = if status == :pane_opened, do: RcPaneBorders.reconcile(state), else: state
    render(state)
    {:noreply, state}
  end

  def handle_info({:status_changed, _}, state), do: {:noreply, state}
  def handle_info({:slot_session_changed, slot, _} = event, state) when is_integer(slot), do: apply_warmth(state, event)
  def handle_info({:slot_ready, slot} = event, state) when is_integer(slot), do: apply_warmth(state, event)
  def handle_info({:slot_starting, slot} = event, state) when is_integer(slot), do: apply_warmth(state, event)
  def handle_info({:slot_visible_changed, _slot, _identifier} = event, state), do: apply_warmth(state, event)
  def handle_info({:attach_state_changed, _, _, _} = event, state), do: apply_warmth(state, event)
  def handle_info({:slot_fully_warmed, _} = event, state), do: apply_warmth(state, event)
  def handle_info({:slot_warmth_dropped, _} = event, state), do: apply_warmth(state, event)

  def handle_info({:poll_state_changed, payload}, state), do: {:noreply, %{state | poll_state: payload}}
  def handle_info({:alert, %{}}, state), do: {:noreply, state}
  def handle_info({kind, _}, state) when kind in [:slot_ready, :slot_starting], do: {:noreply, state}
  def handle_info({:slot_session_changed, _, _}, state), do: {:noreply, state}
  def handle_info({:attach_failed, _, _, _}, state), do: {:noreply, state}
  def handle_info({:attach_consumed, _, _, _}, state), do: {:noreply, state}
  def handle_info({kind, _, _}, state) when kind in [:slot_attach_added, :slot_attach_removed], do: {:noreply, state}

  def handle_info(:clear_max_agents_alert, state), do: render_reply(%{state | max_agents_alert?: false})
  def handle_info(:clear_remote_control_hint, state), do: render_reply(%{state | remote_control_hint: nil})

  def handle_info(:refresh_tick, state) do
    render(state)
    schedule_refresh_tick()
    {:noreply, state}
  end

  def handle_info(:geometry_tick, state) do
    {columns, rows} = RenderState.terminal_geometry()
    schedule_geometry_tick()
    if columns == state.columns and rows == state.rows, do: {:noreply, state}, else: render_reply(%{state | columns: columns, rows: rows})
  end

  def handle_info({:aiur_perf, event}, %{debug_mode?: true} = state) do
    {state, render?} = PerfIntake.fold(state, event)
    if render?, do: render(state)
    {:noreply, state}
  end

  def handle_info({:aiur_perf, _event}, state), do: {:noreply, state}

  def handle_info({:event_debug, entry}, state) do
    state = EventIntake.fold(state, entry)
    render(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(reason, _state) do
    Logger.info("aiur_agent_list phase=terminate reason=#{inspect(reason)} os_pid=#{System.pid()}")
    :ok
  end

  defp subscribe(debug_mode?) do
    AgentPubSub.subscribe_running()
    AgentPubSub.subscribe_status()
    AgentPubSub.subscribe_poll_state()
    AgentPubSub.subscribe_agent_chat_active()
    AgentPubSub.subscribe_prewarm()
    Phoenix.PubSub.subscribe(Aiur.PubSub, Slot.slots_topic())
    Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())
    DebugLog.subscribe()
    if debug_mode?, do: Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Perf.topic())
  end

  defp select(state, amount) do
    state = Selection.move_selection(state, amount)
    render(state)
    {:noreply, state}
  end

  defp apply_controls(state, function) do
    state = function.(state)
    render(state)
    {:noreply, state}
  end

  defp apply_warmth(state, event) do
    {state, changed?} = WarmthIntake.fold(state, event)
    if changed?, do: render(state)
    {:noreply, state}
  end

  defp render_reply(state) do
    render(state)
    {:noreply, state}
  end

  defp safely_seed_attach_pool([], []), do: :ok

  defp safely_seed_attach_pool(identifiers, retain_ids) do
    AttachPool.seed(AttachPool, identifiers, retain_ids)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp schedule_refresh_tick, do: Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
  defp schedule_geometry_tick, do: Process.send_after(self(), :geometry_tick, @geometry_tick_ms)

  defp safe_call(function) do
    function.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
    _, _ -> nil
  end

  defp render(state) do
    state.write_fun.(state |> RenderState.build() |> Renderer.render())
    :ok
  end
end

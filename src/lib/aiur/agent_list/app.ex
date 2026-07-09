defmodule Aiur.AgentList.App do
  @moduledoc """
  Agent-list pane orchestrator.

  Subscribes to `"agents:running"` and `"agents:status"` via
  `Aiur.AgentPubSub`, keeps the current list of agent summaries
  in state, dispatches selection/activation events from
  `Aiur.AgentList.Input`, and renders to stdout through
  `Aiur.AgentList.Renderer`.

  On activate (enter), calls
  `Aiur.PaneManager.open_conversation/3` with the configured command
  template. The default opens an opencode-backed pane session.

  Accepts these test seams:
    * `:write_fun` — function called with the rendered iodata (defaults to `IO.write/1`).
    * `:pane_manager` — name of the PaneManager GenServer.
    * `:orchestrator` — name of the Orchestrator GenServer.
    * `:subscribe?` — subscribe to agent PubSub topics (defaults to `true`).
    * `:command_template` — string with `~s` placeholder filled by the
      selected identifier. Defaults to the opencode pane sentinel.
  """

  use GenServer
  require Logger

  alias Aiur.AgentList.{EventIntake, Renderer, RenderState, Roster, Selection, State, Summaries}
  alias Aiur.{AgentPubSub, Orchestrator, PaneManager}
  alias Aiur.Events.DebugLog
  alias Aiur.Opencode.{AttachPool, Slot}

  # `init/1` and `render/1` go through GenServer-side and IO callbacks
  # whose return shapes dialyzer can't fully trace; the warnings are
  # spurious false positives. Suppress at module scope.
  @dialyzer {:no_return, init: 1, render: 1}
  @dialyzer {:nowarn_function, render: 1}

  @refresh_tick_ms 1_000
  @warmth_event_cap 500
  # Geometry-watch interval. Far faster than the refresh tick so that
  # tmux resizes (caused by another pane opening/closing in the same
  # window) reflow the agent list within a quarter-second — the old
  # 1-second cadence left visibly stale layout until the next refresh.
  @geometry_tick_ms 250

  # Public API ----------------------------------------------------------------

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
  def toggle_remote_control(server \\ __MODULE__),
    do: GenServer.cast(server, :toggle_remote_control)

  @spec adjust_max_concurrent_agents(integer()) :: :ok
  @spec adjust_max_concurrent_agents(GenServer.server(), integer()) :: :ok
  def adjust_max_concurrent_agents(server \\ __MODULE__, delta) when is_integer(delta) do
    GenServer.cast(server, {:adjust_max_concurrent_agents, delta})
  end

  @spec quit() :: no_return()
  @spec quit(GenServer.server()) :: no_return()
  def quit(_server \\ __MODULE__) do
    # q is a global "shut aiur down" keybind, equivalent to Ctrl-C. The
    # earlier implementation cast :quit to this GenServer, but it was
    # supervised with restart: :permanent so the supervisor immediately
    # restarted it — the operator saw the list flash empty for a beat
    # and then re-populate from PubSub instead of actually quitting.
    Logger.info("[user-action] quit source=agent_list")
    Aiur.Shutdown.shutdown(0)
  end

  @spec toggle_help(GenServer.server()) :: :ok
  def toggle_help(server \\ __MODULE__), do: GenServer.cast(server, :toggle_help)

  @spec toggle_layout_orientation(GenServer.server()) :: :ok
  def toggle_layout_orientation(server \\ __MODULE__),
    do: GenServer.cast(server, :toggle_layout_orientation)

  @spec snapshot(GenServer.server()) :: State.t()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  # GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    Logger.info("aiur_agent_list phase=init os_pid=#{System.pid()}")
    opts = Keyword.put_new(opts, :command_template, default_command_template())
    state = State.new(opts)

    if Keyword.get(opts, :subscribe?, true) do
      AgentPubSub.subscribe_running()
      AgentPubSub.subscribe_status()
      AgentPubSub.subscribe_poll_state()
      AgentPubSub.subscribe_agent_chat_active()
      AgentPubSub.subscribe_prewarm()
      Phoenix.PubSub.subscribe(Aiur.PubSub, Slot.slots_topic())
      Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())
      # DebugLog feeds the per-row Latest column (R5/U21) by populating
      # `latest_event_by_id` from every event publish. Subscribed
      # unconditionally — the debug-ticker code path is still gated on
      # debug_mode?, but Latest is always-on.
      DebugLog.subscribe()

      if state.debug_mode? do
        Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Perf.topic())
      end
    end

    schedule_refresh_tick()
    schedule_geometry_tick()
    render(state)

    elapsed = Aiur.Boot.elapsed_ms()

    Logger.info("aiur_agent_list phase=ready elapsed_ms=#{elapsed} agents=#{length(state.summaries)}")

    # Emit through the same aiur_perf channel so the debug footer can
    # show "agent list ready: Xs" from the same data stream.
    Aiur.Perf.event(:agent_list_ready, wall_ms: elapsed)

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:select_previous, state) do
    new_state = Selection.move_selection(state, -1)
    render(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:select_next, state) do
    new_state = Selection.move_selection(state, 1)
    render(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:activate, state) do
    # Both Enter and Shift+Enter open the agent in a new pane. The old
    # swap-in-place path went through `/tui/select-session`, which opencode
    # 1.15.6 responds to with a 200 but then exits the attach process
    # seconds later — that was the "pane dies after a few seconds"
    # bug. Opening a new pane uses pre-warmed slots and is instant.
    if state.selection_focus == :agents do
      activate_selected_agent(state, :new_pane)
    end

    {:noreply, state}
  end

  def handle_cast(:activate_new_pane, state) do
    if state.selection_focus == :agents do
      activate_selected_agent(state, :new_pane)
    end

    {:noreply, state}
  end

  def handle_cast(:attach_selected, state) do
    if state.selection_focus == :agents do
      attach_selected_agent(state)
    end

    {:noreply, state}
  end

  def handle_cast(:toggle_pause, state) do
    state = toggle_selected_agent_pause(state)
    render(state)
    {:noreply, state}
  end

  def handle_cast(:toggle_remote_control, state) do
    state = toggle_selected_agent_remote_control(state)
    render(state)
    {:noreply, state}
  end

  def handle_cast({:adjust_max_concurrent_agents, delta}, state) do
    # ←/→ adjusts the session max regardless of current selection focus —
    # the keybind is global so the operator does not have to navigate to
    # the max chip first. Focus-gating silently swallowed the keypress
    # and made the cap feel un-editable from the agent list.
    Logger.info("[user-action] adjust_max delta=#{delta} source=agent_list")
    result = Orchestrator.adjust_max_concurrent_agents(state.orchestrator, delta)
    Logger.info("[user-action] adjust_max result=#{inspect(result)}")
    state = handle_max_adjust_result(state, result)
    render(state)
    {:noreply, state}
  end

  def handle_cast(:toggle_help, state) do
    new_state = %{state | help_visible?: not Map.get(state, :help_visible?, false)}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:toggle_layout_orientation, state) do
    case RenderState.safe_call(fn -> PaneManager.toggle_orientation(state.pane_manager) end) do
      {:ok, orientation} ->
        Logger.info("[user-action] toggle_layout orientation=#{orientation} source=agent_list")

      _ ->
        :ok
    end

    {:noreply, state}
  end

  defp activate_selected_agent(state, mode) do
    case Enum.at(state.summaries, state.selection_index) do
      %{identifier: identifier} = summary ->
        activate_selected_agent_if_warm(state, identifier, summary, mode)

      _ ->
        :ok
    end
  end

  defp activate_selected_agent_if_warm(state, identifier, summary, mode) do
    cond do
      Summaries.deactivated?(summary) ->
        # 🏁 rows have no live agent and no warm chat pane (AttachPool
        # released the slot during U4). Enter here means "wake this
        # up": route through Orchestrator.resume_agent (which U5 maps
        # to reactivate_issue/2) and open the pane. The agent's first
        # transcript event drives the marker glyph progression as
        # normal (🔘 → ⚪ → 🟢).
        reactivate_and_open(state, identifier, summary, mode)

      not warm_identifier?(state, identifier) ->
        Logger.info("[user-action] open_blocked identifier=#{identifier} source=agent_list reason=not_warm")

      mode == :new_pane and not has_parallel_headroom?(state, identifier) ->
        Logger.info("[user-action] open_blocked identifier=#{identifier} source=agent_list reason=no_headroom")

      true ->
        open_selected_agent(state, identifier, summary, mode)
    end
  end

  defp reactivate_and_open(state, identifier, summary, mode) do
    Logger.info("[user-action] reactivate_on_enter identifier=#{identifier} source=agent_list")

    Task.start(fn -> log_reactivate_result(state, identifier) end)

    open_selected_agent(state, identifier, summary, mode)
  end

  defp log_reactivate_result(state, identifier) do
    case RenderState.safe_call(fn -> Orchestrator.resume_agent(state.orchestrator, identifier) end) do
      {:ok, _} -> :ok
      other -> Logger.debug("reactivate_on_enter resume_agent reply=#{inspect(other)}")
    end
  end

  defp open_selected_agent(state, identifier, summary, mode) do
    Logger.info("[user-action] open_conversation identifier=#{identifier} mode=#{mode} source=agent_list")

    Aiur.Perf.event(:user_pressed_enter,
      identifier: identifier,
      source: :agent_list,
      mode: mode
    )

    command = "#{state.command_template} #{identifier}"
    title = Map.get(summary, :title)
    pane_manager = state.pane_manager

    Task.start(fn -> do_open(pane_manager, identifier, command, title, mode) end)
  end

  defp do_open(pane_manager, identifier, command, title, :new_pane) do
    PaneManager.open_conversation(pane_manager, identifier, command, title: title)
  end

  defp do_open(pane_manager, identifier, command, title, :swap_in_last_used) do
    case PaneManager.attach_conversation(pane_manager, identifier, command, title: title) do
      {:ok, _pane_id} ->
        :ok

      {:error, :no_focused_pane} ->
        PaneManager.open_conversation(pane_manager, identifier, command,
          title: title,
          timeout: 65_000
        )

      {:error, _other} ->
        :ok
    end
  end

  # Whether opening `identifier` will land on a free slot. With
  # deterministic leadoff every active agent has a slot pre-painted in
  # the hidden window — `visible_in` in attach_state means "leadoff
  # painted" now, not "in window 0". The real gate is whether the
  # agent's pane is already open (= in `opened_panes`); if not, the
  # warm path can move its leadoff pane to visible instantly.
  defp has_parallel_headroom?(state, identifier) do
    opened = Map.get(state, :opened_panes, MapSet.new())
    id_str = to_string(identifier)

    # Already open → let PaneManager focus the existing pane (it
    # returns :pane_open_already_visible).
    # Otherwise: true iff the agent has at least one slot attached, so
    # AttachPool can hand the slot back.
    if MapSet.member?(opened, id_str) do
      true
    else
      case Map.get(state.attach_state, id_str) do
        %{attach_count: n} when n >= 1 -> true
        _ -> false
      end
    end
  end

  defp warm_identifier?(state, identifier) do
    case Map.get(state.attach_state, identifier) do
      %{attach_count: n} when n > 0 -> true
      _ -> false
    end
  end

  defp attach_selected_agent(state) do
    case Enum.at(state.summaries, state.selection_index) do
      %{identifier: identifier} = summary ->
        Logger.info("[user-action] attach_selected identifier=#{identifier} source=agent_list")
        command = "#{state.command_template} #{identifier}"
        title = Map.get(summary, :title)
        pane_manager = state.pane_manager

        # Same parking concern as :activate — `attach_conversation`
        # already uses a 65 s call timeout but it still blocks the
        # AgentList process. Run the whole attempt-then-fallback in
        # a Task so keystrokes stay responsive.
        Task.start(fn -> attempt_attach_then_open(pane_manager, identifier, command, title) end)

      _ ->
        :ok
    end
  end

  defp attempt_attach_then_open(pane_manager, identifier, command, title) do
    case PaneManager.attach_conversation(pane_manager, identifier, command, title: title) do
      {:ok, _pane_id} ->
        :ok

      {:error, :no_focused_pane} ->
        PaneManager.open_conversation(pane_manager, identifier, command,
          title: title,
          timeout: 65_000
        )

      {:error, _other} ->
        :ok
    end
  end

  # --- Remote Control pane-border surfacing (#13) ------------------------
  #
  # The RC session URL is remote control's actionable output: a capability
  # token the operator opens on their phone to drive the agent. It rides in
  # the agent's chat-pane top border (set via tmux) rather than the
  # agent-list footer, so it travels with the pane it belongs to and stays
  # unambiguous when several RC agents are open at once.
  #
  # Reconcile runs on `:running_changed` (URL arrives/changes, or RC
  # toggles) and `:pane_opened` (a pane the URL can attach to appears). It
  # diffs the desired border per open pane against what was last applied and
  # only calls tmux for panes that changed, so the 1 Hz running_changed tick
  # doesn't re-issue set-option every second.
  defp reconcile_rc_pane_borders(state) do
    open_panes = safe_list_open_panes(state.pane_manager)
    {changes, applied} = rc_border_changes(open_panes, state.summaries, state.rc_pane_borders)

    Enum.each(changes, fn {pane_id, text} ->
      Aiur.Tmux.set_pane_border(state.tmux, pane_id, text)
    end)

    %{state | rc_pane_borders: applied}
  end

  defp safe_list_open_panes(pane_manager) do
    PaneManager.list_open_panes(pane_manager)
  catch
    :exit, _ -> %{}
  end

  @doc false
  # Pure reconciliation: given the open panes (identifier => pane_id), the
  # agent summaries, and the borders already applied (pane_id => text),
  # return `{changes, next_applied}`. `changes` is the `{pane_id, text | nil}`
  # list to push to tmux (nil clears the border); `next_applied` tracks only
  # currently-open panes, so closed panes self-prune (tmux drops a dead
  # pane's options on its own).
  @spec rc_border_changes(
          %{optional(String.t()) => String.t()},
          [map()],
          %{optional(String.t()) => String.t()}
        ) :: {[{String.t(), String.t() | nil}], %{optional(String.t()) => String.t()}}
  def rc_border_changes(open_panes, summaries, applied) do
    url_by_id =
      summaries
      |> Enum.map(fn s -> {to_string(Map.get(s, :identifier)), rc_border_text(s)} end)
      |> Map.new()

    desired =
      Map.new(open_panes, fn {identifier, pane_id} ->
        {pane_id, Map.get(url_by_id, to_string(identifier))}
      end)

    changes =
      Enum.flat_map(desired, fn {pane_id, text} ->
        if Map.get(applied, pane_id) == text, do: [], else: [{pane_id, text}]
      end)

    next_applied =
      desired
      |> Enum.reject(fn {_pane_id, text} -> is_nil(text) end)
      |> Map.new()

    {changes, next_applied}
  end

  # The border string for a summary, or nil when the agent has no live RC
  # session. `#` is doubled because tmux's `pane-border-format` treats it as
  # the start of a format expansion; claude session URLs carry none today,
  # but doubling stops a stray `#` from corrupting the border.
  defp rc_border_text(%{remote_control: %{status: :on, session_url: url}}) when is_binary(url) do
    " 📱 " <> String.replace(url, "#", "##") <> " "
  end

  defp rc_border_text(_summary), do: nil

  @impl true
  # Pre-warm phase events drive the loading bar shown before agents populate.
  # :ready and errors clear it; a populated agent list also overrides it (the
  # renderer hides the bar once summaries are non-empty), so a missed clear can
  # never strand the bar.
  def handle_info({:prewarm_phase, phase}, state) do
    new_state =
      case phase do
        p when p in [:cloning, :fetching, :building] ->
          %{state | prewarm_active?: true, prewarm_phase: p}

        _ ->
          %{state | prewarm_active?: false, prewarm_phase: nil}
      end

    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:running_changed, summaries}, state) do
    {new_state, slot_ids, retain_ids} = Roster.fold(state, summaries)
    _ = safely_seed_attach_pool(slot_ids, retain_ids)
    new_state = reconcile_rc_pane_borders(new_state)
    render(new_state)
    {:noreply, new_state}
  end

  # Global `agents:chat_active` broadcast — fires every time any
  # agent emits a transcript event. Promotes the marker from 🔘
  # (pane painted, empty) to ⚪ (pane painted, has content). MapSet
  # dedups so repeated broadcasts are no-ops.
  def handle_info({:agent_chat_active, identifier}, state) when is_binary(identifier) do
    if MapSet.member?(state.agents_with_content, identifier) do
      {:noreply, state}
    else
      new_state = update_in(state.agents_with_content, &MapSet.put(&1, identifier))
      render(new_state)
      {:noreply, new_state}
    end
  end

  # The agent-list circle indicator no longer tracks "pane has ever
  # been opened" — it tracks "session is currently visible in some
  # slot", updated via `:slot_session_changed` below. Any other
  # Track pane open/close so the renderer can show 🟢 only when the
  # agent's pane is actually visible in window 0 — not just when
  # AttachPool's `visible_in` is set (which fires at leadoff-paint
  # time, before the user has opened anything).
  def handle_info({:status_changed, %{identifier: id, status: :pane_opened}}, state) do
    new_state =
      state
      |> update_in([:opened_panes], &MapSet.put(&1, to_string(id)))
      |> reconcile_rc_pane_borders()

    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:status_changed, %{identifier: id, status: :pane_closed}}, state) do
    new_state = update_in(state.opened_panes, &MapSet.delete(&1, to_string(id)))
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:status_changed, _}, state), do: {:noreply, state}

  def handle_info({:slot_session_changed, slot_index, identifier}, state)
      when is_integer(slot_index) do
    new_visible =
      case identifier do
        nil -> Map.delete(state.visible_sessions, slot_index)
        id when is_binary(id) -> Map.put(state.visible_sessions, slot_index, id)
      end

    new_state = %{state | visible_sessions: new_visible}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:slot_ready, slot_index}, state) when is_integer(slot_index) do
    new_state = update_in(state.started_slots, &MapSet.put(&1, slot_index))
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:slot_ready, _other}, state), do: {:noreply, state}

  def handle_info({:slot_starting, slot_index}, state) when is_integer(slot_index) do
    new_state = update_in(state.started_slots, &MapSet.put(&1, slot_index))
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:slot_starting, _other}, state), do: {:noreply, state}

  def handle_info({:poll_state_changed, payload}, state) do
    {:noreply, %{state | poll_state: payload}}
  end

  def handle_info({:alert, %{}}, state), do: {:noreply, state}

  def handle_info(:clear_max_agents_alert, state) do
    new_state = %{state | max_agents_alert?: false}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info(:clear_remote_control_hint, state) do
    new_state = %{state | remote_control_hint: nil}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info(:refresh_tick, state) do
    render(state)
    schedule_refresh_tick()
    {:noreply, state}
  end

  def handle_info(:geometry_tick, state) do
    # Re-render whenever the terminal geometry changes so a tmux pane
    # resize (caused by another pane being added/closed) reflows
    # immediately. No-op when nothing changed to avoid wasted writes.
    {cols, rows} = RenderState.terminal_geometry()
    schedule_geometry_tick()

    if cols == state.columns and rows == state.rows do
      {:noreply, state}
    else
      new_state = %{state | columns: cols, rows: rows}
      render(new_state)
      {:noreply, new_state}
    end
  end

  def handle_info({:attach_state_changed, identifier, attach_count, visible_in}, state) do
    entry = %{attach_count: attach_count, visible_in: visible_in}
    new_state = put_in(state.attach_state[identifier], entry)
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:slot_fully_warmed, slot_index}, state) do
    new_state = update_in(state.fully_warmed_slots, &MapSet.put(&1, slot_index))
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:slot_warmth_dropped, slot_index}, state) do
    new_state = update_in(state.fully_warmed_slots, &MapSet.delete(&1, slot_index))
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:attach_failed, _identifier, _slot_index, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:attach_consumed, _identifier, _pane_id, _slot_index}, state) do
    {:noreply, state}
  end

  def handle_info({:slot_attach_added, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info({:slot_attach_removed, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info({:slot_visible_changed, slot_index, identifier}, state) do
    new_visible =
      case identifier do
        nil -> Map.delete(state.visible_sessions, slot_index)
        id when is_binary(id) -> Map.put(state.visible_sessions, slot_index, id)
      end

    new_state = %{state | visible_sessions: new_visible}
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:aiur_perf, event}, %{debug_mode?: true} = state) do
    new_summary = update_perf_summary(state.perf_summary, event)
    new_warmth = absorb_warmth_event(state.warmth_events, event)
    new_state = %{state | perf_summary: new_summary, warmth_events: new_warmth}

    if new_summary != state.perf_summary do
      render(new_state)
    end

    {:noreply, new_state}
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

  # ---------------------------------------------------------------------------
  # Private helpers used by the handle_info clauses above.
  # ---------------------------------------------------------------------------

  # Pull the three milestones the debug footer cares about out of the
  # aiur_perf stream. Everything else is ignored — the user asked for
  # a compact 3-row footer, not a rolling event log.
  defp update_perf_summary(summary, %{phase: :agent_list_ready, meta: %{wall_ms: ms}}) do
    %{summary | agent_list_ready_ms: ms}
  end

  defp update_perf_summary(summary, %{phase: :placeholder_spawn_done, meta: %{wall_ms: ms}}) do
    %{summary | chat_pane_visible_ms: ms}
  end

  defp update_perf_summary(summary, %{phase: :convo_first_paint, meta: %{wall_ms: ms}}) do
    %{summary | opencode_render_ms: ms}
  end

  defp update_perf_summary(summary, _event), do: summary

  defp absorb_warmth_event(events, %{
         phase: phase,
         meta: meta,
         at_ms: at_ms
       })
       when phase in [
              :slot_attach_added,
              :slot_attach_removed,
              :slot_visible_changed
            ] do
    entry = %{
      phase: phase,
      at_ms: at_ms,
      identifier: Map.get(meta, :identifier),
      slot: Map.get(meta, :slot)
    }

    [entry | events] |> Enum.take(@warmth_event_cap)
  end

  defp absorb_warmth_event(events, _other), do: events

  defp schedule_refresh_tick do
    Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
  end

  defp schedule_geometry_tick do
    Process.send_after(self(), :geometry_tick, @geometry_tick_ms)
  end

  defp safely_seed_attach_pool([], []), do: :ok

  defp safely_seed_attach_pool(identifiers, retain_ids) do
    AttachPool.seed(AttachPool, identifiers, retain_ids)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Internals -----------------------------------------------------------------

  defp handle_resume_result(state, {:ok, _}), do: state

  # Any resume_agent / start_queued failure rings the bell and flashes
  # the max chip. Different error codes have different real causes —
  # log the specific reason so the user can tell a capacity issue
  # (:max_concurrent_agents_reached) from a dispatch issue
  # (:not_resumable, :dispatch_failed, :no_running_agent). The red
  # flash alone doesn't tell them which.
  defp handle_resume_result(state, {:error, reason}) do
    Logger.info("[user-action] resume_failed reason=#{inspect(reason)}")
    ring_bell(state)
    schedule_max_agents_alert_clear()
    %{state | max_agents_alert?: true}
  end

  defp handle_max_adjust_result(state, {:ok, _status}), do: state

  defp handle_max_adjust_result(state, _result), do: state

  defp ring_bell(state) do
    state.write_fun.("\a")
    :ok
  end

  defp schedule_max_agents_alert_clear do
    Process.send_after(self(), :clear_max_agents_alert, 750)
  end

  defp toggle_selected_agent_pause(%{selection_focus: :agents} = state) do
    state.summaries
    |> Enum.at(state.selection_index)
    |> toggle_agent_pause(state)
  end

  defp toggle_selected_agent_pause(state), do: state

  defp toggle_agent_pause(%{identifier: identifier, status: :running} = summary, state) do
    cond do
      Summaries.remote_control_on?(summary) ->
        # An RC-on agent is handed off to the Claude app — there is no
        # local headless driver to pause. Surface the hint and no-op.
        rc_hint(state, "Agent is in Remote Control — press `r` to return")

      Summaries.paused?(summary) ->
        Logger.info("[user-action] resume_agent identifier=#{identifier} source=agent_list")
        handle_resume_result(state, Orchestrator.resume_agent(state.orchestrator, identifier))

      true ->
        Logger.info("[user-action] pause_agent identifier=#{identifier} source=agent_list")
        _ = Orchestrator.pause_agent(state.orchestrator, identifier)
        state
    end
  end

  defp toggle_agent_pause(%{identifier: identifier, status: :queued}, state) do
    Logger.info("[user-action] start_queued_agent identifier=#{identifier} source=agent_list")
    handle_resume_result(state, Orchestrator.resume_agent(state.orchestrator, identifier))
  end

  defp toggle_agent_pause(_summary, state), do: state

  defp toggle_selected_agent_remote_control(%{selection_focus: :agents} = state) do
    state.summaries
    |> Enum.at(state.selection_index)
    |> toggle_agent_remote_control(state)
  end

  defp toggle_selected_agent_remote_control(state), do: state

  # `r` only means something for a live agent row. Capability gating
  # (codex / remote worker / no workspace) lives in the Orchestrator —
  # we call `set_remote_control` and translate whatever it returns into
  # a status-line hint, rather than duplicating the gate here.
  defp toggle_agent_remote_control(%{identifier: identifier, status: :running} = summary, state) do
    desired = not Summaries.remote_control_on?(summary)
    action = if desired, do: "on", else: "off"
    Logger.info("[user-action] remote_control identifier=#{identifier} desired=#{action} source=agent_list")
    result = Orchestrator.set_remote_control(state.orchestrator, identifier, desired)
    handle_remote_control_result(state, result)
  end

  defp toggle_agent_remote_control(_summary, state) do
    rc_hint(state, "Remote Control requires a local Claude agent")
  end

  defp handle_remote_control_result(state, {:ok, :on}) do
    rc_hint(state, "Switching to remote — REPL + Claude app, same transcript")
  end

  defp handle_remote_control_result(state, {:ok, :off}) do
    rc_hint(state, "Remote off — re-dispatching on the default backend")
  end

  defp handle_remote_control_result(state, {:error, :unsupported}) do
    rc_hint(state, "Remote Control requires a local Claude agent")
  end

  defp handle_remote_control_result(state, {:error, :remote_unsupported}) do
    rc_hint(state, "Remote Control is local-only — this agent runs on a remote worker")
  end

  defp handle_remote_control_result(state, {:error, :workspace_unavailable}) do
    rc_hint(state, "Remote Control unavailable — agent has no workspace yet")
  end

  defp handle_remote_control_result(state, {:error, _reason}) do
    rc_hint(state, "Remote Control unavailable")
  end

  defp rc_hint(state, message) do
    schedule_remote_control_hint_clear()
    %{state | remote_control_hint: message}
  end

  defp schedule_remote_control_hint_clear do
    Process.send_after(self(), :clear_remote_control_hint, 4_000)
  end

  defp render(state) do
    state.write_fun.(Renderer.render(RenderState.build(state)))
    :ok
  end

  defp default_command_template do
    "__aiur_opencode__"
  end
end

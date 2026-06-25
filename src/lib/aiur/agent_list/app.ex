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

  alias Aiur.AgentList.Renderer
  alias Aiur.{AgentPubSub, Config, HttpServer, Orchestrator, PaneManager, Tracker}
  alias Aiur.Events.{DebugLog, SubscriptionStore}
  alias Aiur.Opencode.{AttachPool, Slot}

  # `init/1` and `render/1` go through GenServer-side and IO callbacks
  # whose return shapes dialyzer can't fully trace; the warnings are
  # spurious false positives. Suppress at module scope.
  @dialyzer {:no_return, init: 1, render: 1}
  @dialyzer {:nowarn_function, render: 1}

  @refresh_tick_ms 1_000
  @warmth_event_cap 500
  # Cap on the in-memory debug-event ticker buffer. The renderer trims
  # further based on available pane height, but this stops unbounded
  # growth if the operator leaves --debug on for hours.
  @debug_event_cap 200
  # Geometry-watch interval. Far faster than the refresh tick so that
  # tmux resizes (caused by another pane opening/closing in the same
  # window) reflow the agent list within a quarter-second — the old
  # 1-second cadence left visibly stale layout until the next refresh.
  @geometry_tick_ms 250

  @type state :: %{
          summaries: [map()],
          selection_index: non_neg_integer(),
          selection_focus: :agents | :max_agents,
          columns: pos_integer(),
          rows: pos_integer(),
          write_fun: (iodata() -> any()),
          pane_manager: GenServer.name(),
          command_template: String.t(),
          orchestrator: GenServer.name(),
          max_agents_alert?: boolean(),
          remote_control_hint: String.t() | nil
        }

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

  @spec snapshot(GenServer.server()) :: state()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  # GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    Logger.info("aiur_agent_list phase=init os_pid=#{System.pid()}")
    write_fun = Keyword.get(opts, :write_fun, &IO.write/1)
    pane_manager = Keyword.get(opts, :pane_manager, PaneManager)
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
    tmux = Keyword.get(opts, :tmux, Aiur.Tmux)
    command_template = Keyword.get(opts, :command_template, default_command_template())
    {cols, rows} = terminal_geometry()

    debug_mode? = Keyword.get(opts, :debug?, debug_env?())

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

      if debug_mode? do
        Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Perf.topic())
      end
    end

    {prewarm_active?, prewarm_phase} = initial_prewarm_state()

    state = %{
      summaries: [],
      selection_index: 0,
      selection_focus: :agents,
      columns: cols,
      rows: rows,
      help_visible?: false,
      max_agents_alert?: false,
      prewarm_active?: prewarm_active?,
      prewarm_phase: prewarm_phase,
      # Transient status-line hint string driven by the `r`/Space
      # remote-control keybinds. Set by `rc_hint/2`, auto-cleared after
      # a few seconds via `:clear_remote_control_hint`. nil = no hint.
      remote_control_hint: nil,
      write_fun: write_fun,
      pane_manager: pane_manager,
      orchestrator: orchestrator,
      tmux: tmux,
      command_template: command_template,
      # pane_id => RC border text currently applied to that pane's top
      # border, so reconcile only re-issues tmux set-option when the text
      # actually changes. The text holds the RC session URL (a capability
      # token) and so lives only in memory — never logged or rendered.
      rc_pane_borders: %{},
      # slot_index → currently-visible identifier (nil = slot idle).
      # Updated on `:slot_session_changed` PubSub events from Slot workers.
      # This is the single source of truth for the agent-list circle
      # indicator — the legacy `open_pane_ids` (historical opens) is gone.
      visible_sessions: %{},
      # Cached orchestrator polling state — updated only on PubSub
      # `:poll_state_changed` broadcasts so the 1 Hz render tick never
      # has to GenServer.call into the orchestrator (which blocks for
      # seconds while it does HTTP polls). `max_concurrent_agents` is
      # also carried here so the render never has to query for it.
      poll_state: %{
        checking?: false,
        next_poll_due_at_ms: nil,
        max_concurrent_agents: nil
      },
      debug_mode?: debug_mode?,
      # %{identifier => %{attach_count, visible_in}} mirrored from
      # AttachPool's :attach_state_changed broadcasts. Drives the
      # 4-state ⏳/🔘/⚪/🟢 marker per row.
      attach_state: %{},
      # Slot indexes that have reached :ready (opencode-serve up,
      # accepting attach calls). One status glyph per entry under the
      # bottom nav: in-progress when not yet fully warmed, finished
      # once every active agent is attached.
      started_slots: MapSet.new(),
      fully_warmed_slots: MapSet.new(),
      # Identifiers currently shown in a chat pane (window 0). Populated
      # by `AgentPubSub.broadcast_status_change(_, :pane_opened)` from
      # PaneManager, cleared on `:pane_closed`. The renderer uses this
      # to render 🟢 (truly open in a pane) instead of the prior
      # behavior of mapping AttachPool's `visible_in` to 🟢 — that
      # field actually means "slot's leadoff was painted in the hidden
      # window", which is the ⚪ state from the user's perspective.
      opened_panes: MapSet.new(),
      # Identifiers that have emitted at least one transcript event in
      # this run. Promotes the marker from 🔘 (pane painted but empty)
      # to ⚪ (pane painted AND opening will show useful content).
      # Populated from the global `agents:chat_active` topic that
      # AgentPubSub fires on every transcript event; duplicates are
      # harmless because MapSet.put is idempotent.
      agents_with_content: MapSet.new(),
      # Per-identifier most recent event for the agent-list `Latest`
      # column (R5/U21). Populated from `DebugLog` broadcasts —
      # every published event on a `ticket.<id>.…` topic updates the
      # entry for that ticket. Map value shape:
      # `%{topic: String.t(), message: String.t(), timestamp: DateTime.t()}`.
      latest_event_by_id: %{},
      # Per-identifier count of currently-open `attention.*` slugs,
      # driving the `❗` / `❗N` slot in the State column. Refreshed
      # from `Aiur.Events.SubscriptionStore.snapshot/1` on every
      # `running_changed` broadcast (agents come and go infrequently
      # enough that polling on summary updates beats per-event
      # incremental tracking).
      open_attentions_by_id: %{},
      # Per-identifier ring of recent progress samples for the
      # `[bar] ETA` column (R2). Agents publish
      # `ticket.<id>.agent.progress` with `%{percent: 0..100}` payload
      # and `Aiur.ProgressTracker` derives the bar + ETA on render.
      # Sample shape: `[{percent, monotonic_ms}, …]` newest first,
      # bounded by ProgressTracker.@max_samples.
      progress_by_id: %{},
      # Per-identifier active workflow phase, driving the running-state
      # status emoji (#68). Populated from
      # `ticket.<id>.agent.phase.<brainstorm|plan|work|review>.start`
      # publishes (last `.start` wins); the matching `.end` clears it.
      # Value is one of `:brainstorm | :plan | :work | :review`.
      phase_by_identifier: %{},
      warm_status_dark_mode?: warm_status_dark_mode_default(),
      # Ring buffer of warmth-related aiur_perf events (debug mode
      # only). Capped at @warmth_event_cap to avoid unbounded growth.
      warmth_events: [],
      # Compact 3-row debug-footer state. Each field is `nil` until
      # the corresponding aiur_perf event lands, then holds {wall_ms,
      # at_ms} so the footer can show "agent list ready: 4.0s",
      # "chat pane visible: 0.1s", "opencode render: 7.2s". Newest
      # event wins per slot — if the user opens multiple chats, the
      # footer reflects the most recent open.
      perf_summary: %{
        agent_list_ready_ms: nil,
        chat_pane_visible_ms: nil,
        opencode_render_ms: nil
      },
      # Ring buffer of debug-only event lifecycle marks (publish /
      # receive / read). Newest first; capped at @debug_event_cap.
      # Empty in non-debug mode. Renderer further trims to available
      # pane height.
      debug_events: []
    }

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
    new_state = move_selection(state, -1)
    render(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:select_next, state) do
    new_state = move_selection(state, 1)
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
    case safe_call(fn -> PaneManager.toggle_orientation(state.pane_manager) end) do
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
      deactivated_summary?(summary) ->
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
    case safe_call(fn -> Orchestrator.resume_agent(state.orchestrator, identifier) end) do
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
    summaries = visible_summaries(summaries)
    selection_focus = if state.summaries == [] and summaries != [], do: :agents, else: state.selection_focus
    new_state = clamp_selection(%{state | summaries: summaries, selection_focus: selection_focus})

    # Two derived sets:
    #
    # - `visible_ids` (every :running summary): drives per-id map
    #   compaction. `:deactivated` rows stay in the AgentList so their
    #   bar / latest / attention chips survive across the human-review
    #   transition.
    # - `slot_ids` (visible minus :paused minus :deactivated): the
    #   spawn-eligible set. Drives AttachPool seeding so a `:deactivated`
    #   row releases its warmed opencode pane and AttachPool reclaims the
    #   slot for newly-queued agents the user starts in its place.
    # - `retain_ids` (visible :paused, not :deactivated): the keep-pane
    #   set. A Ctrl+C pause holds the agent's opencode pane open until an
    #   explicit close (second Ctrl+C → :deactivated). Passing these to
    #   seed keeps their attachment instead of detaching on pause.
    visible_ids =
      summaries
      |> Enum.filter(fn s -> Map.get(s, :status) == :running end)
      |> Enum.map(&Map.get(&1, :identifier))
      |> Enum.reject(&is_nil/1)

    slot_ids =
      summaries
      |> Enum.filter(fn s ->
        Map.get(s, :status) == :running and
          not paused_summary?(s) and
          not deactivated_summary?(s)
      end)
      |> Enum.map(&Map.get(&1, :identifier))
      |> Enum.reject(&is_nil/1)

    retain_ids =
      summaries
      |> Enum.filter(fn s ->
        Map.get(s, :status) == :running and
          paused_summary?(s) and
          not deactivated_summary?(s)
      end)
      |> Enum.map(&Map.get(&1, :identifier))
      |> Enum.reject(&is_nil/1)

    _ = safely_seed_attach_pool(slot_ids, retain_ids)

    visible_set = MapSet.new(Enum.map(visible_ids, &to_string/1))

    # Seed a synthetic (100, now) progress sample for every
    # `:deactivated` summary that doesn't already have a 100-percent
    # head. Covers two cases:
    #   - Live `:working → :deactivated` transitions where the agent
    #     never emitted a 100% sample (U1's prompt fixes this going
    #     forward, but pre-U1 agents and complexity:1 fast-paths may
    #     still flip the label without an explicit emit).
    #   - Boot-revived `:deactivated` entries (U6) that have never
    #     emitted any progress samples at all.
    progress_by_id =
      seed_deactivated_progress_samples(
        Map.take(new_state.progress_by_id, MapSet.to_list(visible_set)),
        summaries
      )

    new_state = %{
      new_state
      | # Trim `agents_with_content` so a stopped agent doesn't keep
        # its ⚪ glyph if it returns later — it'll re-earn ⚪ on the
        # next transcript event after re-dispatch. Use visible_set so
        # `:deactivated` rows preserve the ⚪ glyph they earned while
        # working.
        agents_with_content: MapSet.intersection(new_state.agents_with_content, visible_set),
        # Refresh the `❗` counts from SubscriptionStore on every
        # running_changed — agents come and go infrequently enough
        # that polling here beats threading a separate broadcast
        # through the attention-emit path.
        open_attentions_by_id: refresh_open_attentions(visible_set),
        # Trim Latest column entries to visible_set so `:deactivated`
        # rows keep their most-recent event message; a stale entry for
        # an id that's no longer running just wastes row space and is
        # misleading.
        latest_event_by_id: Map.take(new_state.latest_event_by_id, MapSet.to_list(visible_set)),
        # Trim active-phase entries to visible_set so a stopped agent's
        # last phase doesn't linger on a row it no longer owns.
        phase_by_identifier: Map.take(new_state.phase_by_identifier, MapSet.to_list(visible_set)),
        progress_by_id: progress_by_id
    }

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
    state =
      state
      |> record_latest_event(entry)
      |> record_progress_sample(entry)
      |> record_phase(entry)

    state =
      if state.debug_mode? do
        new_events = [entry | state.debug_events] |> Enum.take(@debug_event_cap)
        %{state | debug_events: new_events}
      else
        state
      end

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

  defp refresh_open_attentions(active_set) do
    Enum.reduce(MapSet.to_list(active_set), %{}, fn id, acc ->
      case attention_count_for(id) do
        n when is_integer(n) -> Map.put(acc, id, n)
        _ -> acc
      end
    end)
  end

  defp attention_count_for(id) do
    case SubscriptionStore.snapshot(id) do
      %{open_attentions: list} when is_list(list) -> length(list)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  # Folds `ticket.<id>.agent.progress[.<source>]` publishes into the
  # per-id ProgressTracker sample ring with a source-aware ratchet:
  #
  #   - `agent.progress.checkin` (operator-driven check-in) ALWAYS
  #     records — the agent's attested 1–10 estimate trumps prior
  #     phase guesses, even when it lowers the current value.
  #   - `agent.progress.phase` (phase boundary) and the bare
  #     `agent.progress` topic record only when `percent` is greater
  #     than or equal to the current head — phase guesses can ratchet
  #     up over an agent estimate (e.g. pr.opened → 100) but cannot
  #     drag it back down.
  defp record_progress_sample(state, %{kind: :publish, topic: topic, body: body})
       when is_binary(topic) and is_map(body) do
    with {:ok, id, source} <- parse_progress_topic(topic),
         percent when is_integer(percent) or is_float(percent) <- progress_percent(body) do
      maybe_push_progress(state, id, trunc(percent), source)
    else
      _ -> state
    end
  end

  defp record_progress_sample(state, _entry), do: state

  # Folds `ticket.<id>.agent.phase.<phase>.<start|end>` publishes into
  # the per-id active-phase map that drives the running-state status
  # emoji (#68). `.start` sets the phase (last start wins); `.end`
  # clears it only when it matches the currently-tracked phase, so a
  # late `.end` for a superseded phase can't wipe a newer `.start`.
  defp record_phase(state, %{kind: :publish, topic: topic}) when is_binary(topic) do
    case parse_phase_topic(topic) do
      {:ok, id, phase, :start} ->
        %{state | phase_by_identifier: Map.put(state.phase_by_identifier, id, phase)}

      {:ok, id, phase, :end} ->
        if Map.get(state.phase_by_identifier, id) == phase do
          %{state | phase_by_identifier: Map.delete(state.phase_by_identifier, id)}
        else
          state
        end

      :error ->
        state
    end
  end

  defp record_phase(state, _entry), do: state

  defp parse_phase_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.agent\.phase\.(brainstorm|plan|work|review)\.(start|end)\z}, topic) do
      [_, id, phase, edge] -> {:ok, id, phase_atom(phase), edge_atom(edge)}
      _ -> :error
    end
  end

  defp phase_atom("brainstorm"), do: :brainstorm
  defp phase_atom("plan"), do: :plan
  defp phase_atom("work"), do: :work
  defp phase_atom("review"), do: :review

  defp edge_atom("start"), do: :start
  defp edge_atom("end"), do: :end

  defp parse_progress_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.agent\.progress(?:\.(checkin|phase))?\z}, topic) do
      [_, id, "checkin"] -> {:ok, id, :checkin}
      [_, id, "phase"] -> {:ok, id, :phase}
      [_, id] -> {:ok, id, :phase}
      _ -> :error
    end
  end

  defp maybe_push_progress(state, id, percent, source) do
    existing = Map.get(state.progress_by_id, id, [])

    if accept_progress?(source, percent, existing) do
      now_ms = System.monotonic_time(:millisecond)
      updated = Aiur.ProgressTracker.record(existing, percent, now_ms)
      %{state | progress_by_id: Map.put(state.progress_by_id, id, updated)}
    else
      state
    end
  end

  defp accept_progress?(:checkin, _percent, _samples), do: true
  defp accept_progress?(:phase, percent, samples), do: percent >= head_percent(samples)
  defp accept_progress?(_source, _percent, _samples), do: false

  defp head_percent([{percent, _ts} | _]) when is_integer(percent), do: percent
  defp head_percent(_), do: 0

  defp progress_percent(body) do
    cond do
      is_number(body[:percent]) -> body[:percent]
      is_number(body["percent"]) -> body["percent"]
      true -> nil
    end
  end

  # Map an `event_debug` entry onto the per-id `Latest` column store.
  # Only `:publish` advances the entry — `:receive` is a fan-out echo
  # of the same event the publisher already recorded, and `:read` is a
  # downstream marker that doesn't represent a new event landing on
  # the ticket. Topic shape is `ticket.<id>.<surface>.<verb>`; anything
  # else (system topics, etc.) is ignored.
  defp record_latest_event(state, %{kind: :publish, topic: topic, body: body})
       when is_binary(topic) do
    case extract_ticket_id(topic) do
      nil ->
        state

      id ->
        latest = %{
          topic: topic,
          message: event_message(topic, body),
          timestamp: DateTime.utc_now()
        }

        %{state | latest_event_by_id: Map.put(state.latest_event_by_id, id, latest)}
    end
  end

  defp record_latest_event(state, _entry), do: state

  defp extract_ticket_id("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [id, _] -> id
      _ -> nil
    end
  end

  defp extract_ticket_id(_), do: nil

  # Best-effort one-line message for the Latest column. Prefers an
  # explicit `:message` field on the event body; falls back to the
  # last verb segment of the topic (e.g. `branch.push` → `branch push`).
  defp event_message(topic, body) when is_map(body) do
    cond do
      is_binary(body[:message]) -> body[:message]
      is_binary(body["message"]) -> body["message"]
      true -> topic_verb(topic)
    end
  end

  defp event_message(topic, _body), do: topic_verb(topic)

  defp topic_verb(topic) do
    case String.split(topic, ".") do
      ["ticket", _id | rest] -> Enum.join(rest, " ")
      parts -> Enum.join(parts, " ")
    end
  end

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

  defp warm_status_dark_mode_default do
    Application.get_env(:aiur, :warm_status_dark_mode?, true)
  end

  defp safely_seed_attach_pool([], []), do: :ok

  defp safely_seed_attach_pool(identifiers, retain_ids) do
    AttachPool.seed(AttachPool, identifiers, retain_ids)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp debug_env? do
    case System.get_env("AIUR_DEBUG") do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["1", "true", "yes"]

      _ ->
        false
    end
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

  defp paused_summary?(summary) do
    Map.get(summary, :work_state) in [:paused, "paused"]
  end

  defp deactivated_summary?(summary) do
    Map.get(summary, :work_state) in [:deactivated, "deactivated"]
  end

  # For each `:deactivated` summary, ensure its `progress_by_id` ring
  # contains a 100-percent sample as the head. Inserts via
  # `Aiur.ProgressTracker.record/3`, which dedups by monotonic time —
  # repeated insertions of the same 100 sample do not accumulate.
  defp seed_deactivated_progress_samples(progress_by_id, summaries) do
    now_ms = System.monotonic_time(:millisecond)

    Enum.reduce(summaries, progress_by_id, fn summary, acc ->
      maybe_seed_deactivated_sample(summary, acc, now_ms)
    end)
  end

  defp maybe_seed_deactivated_sample(summary, progress_by_id, now_ms) do
    id = Map.get(summary, :identifier)

    cond do
      not deactivated_summary?(summary) ->
        progress_by_id

      not is_binary(id) ->
        progress_by_id

      head_at_100?(Map.get(progress_by_id, id)) ->
        progress_by_id

      true ->
        existing = Map.get(progress_by_id, id, [])
        updated = Aiur.ProgressTracker.record(existing, 100, now_ms)
        Map.put(progress_by_id, id, updated)
    end
  end

  defp head_at_100?([{100, _ts} | _]), do: true
  defp head_at_100?(_), do: false

  defp toggle_selected_agent_pause(%{selection_focus: :agents} = state) do
    state.summaries
    |> Enum.at(state.selection_index)
    |> toggle_agent_pause(state)
  end

  defp toggle_selected_agent_pause(state), do: state

  defp toggle_agent_pause(%{identifier: identifier, status: :running} = summary, state) do
    cond do
      remote_control_on_summary?(summary) ->
        # An RC-on agent is handed off to the Claude app — there is no
        # local headless driver to pause. Surface the hint and no-op.
        rc_hint(state, "Agent is in Remote Control — press `r` to return")

      paused_summary?(summary) ->
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
    desired = not remote_control_on_summary?(summary)
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

  defp remote_control_on_summary?(%{remote_control: %{status: status}})
       when status in [:launching, :on],
       do: true

  defp remote_control_on_summary?(_summary), do: false

  defp rc_hint(state, message) do
    schedule_remote_control_hint_clear()
    %{state | remote_control_hint: message}
  end

  defp schedule_remote_control_hint_clear do
    Process.send_after(self(), :clear_remote_control_hint, 4_000)
  end

  # Navigation forms one continuous ring across the agent rows and the
  # max-agents chip:
  #
  #   max_agents → first agent → ... → last agent → max_agents → first ...
  #
  # ↑ from the first row and ↓ from the last row both land on the chip,
  # and the chip's own ↑/↓ continues into the opposite end of the list.
  defp move_selection(state, delta) do
    count = length(state.summaries)

    cond do
      count == 0 ->
        %{state | selection_index: 0, selection_focus: :max_agents}

      state.selection_focus == :max_agents ->
        %{state | selection_index: chip_entry_index(count, delta), selection_focus: :agents}

      at_edge?(state, count, delta) ->
        %{state | selection_focus: :max_agents}

      true ->
        new_index = rem(state.selection_index + delta + count, count)
        %{state | selection_index: new_index, selection_focus: :agents}
    end
  end

  # When leaving the chip, ↓ lands on the first row and ↑ on the last.
  defp chip_entry_index(_count, delta) when delta > 0, do: 0
  defp chip_entry_index(count, _delta), do: count - 1

  # The two ring edges that hand selection back to the chip: row 0 going
  # up, or the last row going down.
  defp at_edge?(%{selection_index: 0}, _count, delta) when delta < 0, do: true
  defp at_edge?(%{selection_index: idx}, count, delta) when delta > 0 and idx == count - 1, do: true
  defp at_edge?(_state, _count, _delta), do: false

  defp clamp_selection(state) do
    count = length(state.summaries)

    cond do
      count == 0 -> %{state | selection_index: 0}
      state.selection_index >= count -> %{state | selection_index: count - 1}
      true -> state
    end
  end

  # Canonical "what's shown to the user" transform. Applied on intake so
  # state.summaries matches what the renderer draws — keeping the :activate
  # handler's Enum.at index aligned with the visible row.
  defp visible_summaries(summaries) do
    summaries
    |> Enum.reject(fn s ->
      tag = Map.get(s, :tag)
      tag in ["agent:cancelled", "agent:canceled", "agent:done"]
    end)
    |> Enum.sort_by(fn s ->
      # Group by live work state, then by numeric identifier ASCENDING
      # within each group. Previously
      # sorted identifiers as strings, so "10" came before "5" — the
      # user explicitly asked for natural numeric order within each
      # status-emoji bucket.
      emoji_bucket = emoji_sort_key(s)
      id_key = identifier_sort_key(Map.get(s, :identifier))
      {emoji_bucket, id_key}
    end)
  end

  # Map live work state to a stable sort bucket. Lower = higher in the
  # list. Warm readiness can change per identifier without reshuffling
  # rows, so ⏳ and 🟢 stay in the same working bucket.
  defp emoji_sort_key(%{status: :queued}), do: 4

  defp emoji_sort_key(%{status: :running} = summary) do
    case Map.get(summary, :work_state) do
      # 🟢 actively working — most useful to see first
      :working -> 0
      # ⏸️ paused — still alive, less urgent than working
      :paused -> 1
      # 💤 sleeping (idle stream-close) — still alive and mid-turn, just
      # quiet; sorts with :paused, above finished/errored rows.
      :sleeping -> 1
      # 🔴 error — surface above queued but below healthy
      :error -> 2
      # 🏁 deactivated (awaiting human review) — finished work, lives
      # at 100% green; same bucket as :error so 🏁 sits between active
      # work and the catch-all (a later iteration may sink 🏁 to the
      # bottom — see plan scope "Deferred for later").
      :deactivated -> 2
      _ -> 3
    end
  end

  defp emoji_sort_key(_), do: 5

  # Parse identifier as integer for natural numeric ordering. Falls
  # back to the original string for non-numeric identifiers (test
  # fixtures like "MT-FOCUS" or future namespaced ids) so they group
  # together rather than crash the sort.
  defp identifier_sort_key(nil), do: {1, ""}

  defp identifier_sort_key(identifier) when is_binary(identifier) do
    case Integer.parse(identifier) do
      {n, ""} -> {0, n}
      _ -> {1, identifier}
    end
  end

  defp identifier_sort_key(other), do: {1, to_string(other)}

  # On boot, reflect an in-flight pre-warm so a launch mid-build resumes the bar
  # at the live phase instead of starting blank. Safe when RepoBase is not up.
  defp initial_prewarm_state do
    case prewarm_status() do
      {phase, _base} when phase in [:cloning, :fetching, :building] -> {true, phase}
      _ -> {false, nil}
    end
  end

  defp prewarm_status do
    if Process.whereis(Aiur.RepoBase), do: Aiur.RepoBase.status(), else: {:idle, nil}
  rescue
    _ -> {:idle, nil}
  end

  defp render(state) do
    # Re-query geometry on every render: tmux resizes panes after splits and
    # doesn't update COLUMNS/LINES in our env, so the values captured at
    # init/1 go stale.
    {cols, rows} = terminal_geometry()

    render_state =
      state
      |> Map.take([:summaries, :selection_index, :selection_focus, :help_visible?, :max_agents_alert?])
      |> Map.put(:columns, cols)
      |> Map.put(:rows, rows)
      |> Map.put(:project_label, project_label())
      |> Map.put(:dashboard_url, dashboard_url())
      |> Map.put(:agent_kind, agent_kind())
      |> Map.put(:agent_count, active_agent_count(state.summaries))
      |> Map.put(:max_agents, max_agents_from_state(state))
      |> Map.put(:visible_sessions, state.visible_sessions)
      |> Map.put(:debug_mode?, Map.get(state, :debug_mode?, false))
      |> Map.put(:perf_summary, Map.get(state, :perf_summary, %{}))
      |> Map.put(:warmth_events, Map.get(state, :warmth_events, []))
      |> Map.put(:debug_events, Map.get(state, :debug_events, []))
      |> Map.put(:attach_state, Map.get(state, :attach_state, %{}))
      |> Map.put(:started_slots, Map.get(state, :started_slots, MapSet.new()))
      |> Map.put(:fully_warmed_slots, Map.get(state, :fully_warmed_slots, MapSet.new()))
      |> Map.put(:opened_panes, Map.get(state, :opened_panes, MapSet.new()))
      |> Map.put(:agents_with_content, Map.get(state, :agents_with_content, MapSet.new()))
      |> Map.put(:latest_event_by_id, Map.get(state, :latest_event_by_id, %{}))
      |> Map.put(:phase_by_identifier, Map.get(state, :phase_by_identifier, %{}))
      |> Map.put(:open_attentions_by_id, Map.get(state, :open_attentions_by_id, %{}))
      |> Map.put(:progress_by_id, Map.get(state, :progress_by_id, %{}))
      |> Map.put(
        :warm_status_dark_mode?,
        Map.get(state, :warm_status_dark_mode?, true)
      )
      |> Map.put(:remote_control_hint, Map.get(state, :remote_control_hint))
      |> Map.put(:prewarm_active?, Map.get(state, :prewarm_active?, false))
      |> Map.put(:prewarm_phase, Map.get(state, :prewarm_phase))
      |> Map.put(:truecolor?, truecolor_supported?())

    state.write_fun.(Renderer.render(render_state))
    :ok
  end

  defp project_label do
    case safe_call(fn -> Tracker.project_identity() end) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp dashboard_url do
    host = safe_call(fn -> Config.server_host() end)
    port = safe_call(fn -> HttpServer.bound_port() end) || safe_call(fn -> Config.server_port() end)

    cond do
      not is_integer(port) -> nil
      port <= 0 -> nil
      is_binary(host) and host != "" -> "http://#{host}:#{port}/"
      true -> "http://127.0.0.1:#{port}/"
    end
  end

  defp agent_kind do
    case safe_call(fn -> Config.agent_kind() end) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp active_agent_count(summaries) when is_list(summaries) do
    Enum.count(summaries, fn
      %{status: :running} = summary -> not paused_summary?(summary)
      _ -> false
    end)
  end

  # Read from the cached poll_state payload. The orchestrator publishes
  # `max_concurrent_agents` in every `:poll_state_changed` broadcast, so
  # render avoids the 5 s `Orchestrator.max_concurrent_agents/0` GenServer.call
  # that previously froze arrow-key input during poll cycles.
  defp max_agents_from_state(%{poll_state: %{max_concurrent_agents: n}})
       when is_integer(n) and n > 0, do: n

  defp max_agents_from_state(_state), do: nil

  # Note: the previous `max_agents/1` private helper called
  # `Orchestrator.max_concurrent_agents` synchronously and blocked the
  # render tick for up to 5 s during poll cycles. It was replaced by
  # `max_agents_from_state/1` (cache + broadcast). Do NOT reintroduce a
  # blocking call here without also updating the broadcast path.

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
    _, _ -> nil
  end

  # 24-bit color support, detected from COLORTERM (set to "truecolor" or
  # "24bit" by modern terminals). Drives the MODEL column's per-model colors:
  # truecolor terminals get the exact website hexes, others the nearest ANSI.
  defp truecolor_supported? do
    System.get_env("COLORTERM") in ["truecolor", "24bit"]
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

  defp default_command_template do
    "__aiur_opencode__"
  end
end

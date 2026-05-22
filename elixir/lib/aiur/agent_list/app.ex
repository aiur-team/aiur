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

  # `init/1` and `render/1` go through GenServer-side and IO callbacks
  # whose return shapes dialyzer can't fully trace; the warnings are
  # spurious false positives. Suppress at module scope.
  @dialyzer {:no_return, init: 1, render: 1}
  @dialyzer {:nowarn_function, render: 1}

  @refresh_tick_ms 1_000
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
          max_agents_alert?: boolean()
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
  Attach the currently-selected agent to the most-recently-focused chat
  pane (the same slot rebuilds with the new identifier). When no pane
  is currently focused, falls through to `activate/1` (open in a new
  slot). Triggered by the `a` keybind in `input.ex`.
  """
  @spec attach_selected(GenServer.server()) :: :ok
  def attach_selected(server \\ __MODULE__), do: GenServer.cast(server, :attach_selected)

  @spec toggle_pause(GenServer.server()) :: :ok
  def toggle_pause(server \\ __MODULE__), do: GenServer.cast(server, :toggle_pause)

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
    write_fun = Keyword.get(opts, :write_fun, &IO.write/1)
    pane_manager = Keyword.get(opts, :pane_manager, PaneManager)
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
    command_template = Keyword.get(opts, :command_template, default_command_template())
    {cols, rows} = terminal_geometry()

    debug_mode? = Keyword.get(opts, :debug?, debug_env?())

    if Keyword.get(opts, :subscribe?, true) do
      AgentPubSub.subscribe_running()
      AgentPubSub.subscribe_status()
      AgentPubSub.subscribe_poll_state()
      Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Opencode.Slot.slots_topic())
      Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Opencode.AttachPool.topic())

      if debug_mode? do
        Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Perf.topic())
      end
    end

    state = %{
      summaries: [],
      selection_index: 0,
      selection_focus: :agents,
      columns: cols,
      rows: rows,
      help_visible?: false,
      max_agents_alert?: false,
      write_fun: write_fun,
      pane_manager: pane_manager,
      orchestrator: orchestrator,
      command_template: command_template,
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
      # Identifiers whose opencode-attach has been pre-warmed by
      # `Aiur.Opencode.AttachPool` and is sitting in `aiur-hidden`
      # ready to instant-open. Renderer paints a ⚡ next to these
      # rows so the user knows they'll open in <100 ms.
      warm_identifiers: MapSet.new(),
      # Identifiers whose attach is currently being warmed (Slot.select
      # in flight, opencode-attach booting). Used to suppress the
      # misleading ● marker — :slot_session_changed fires during
      # Slot.select, which would otherwise paint ● on a row whose
      # pane isn't actually visible yet.
      warming_identifiers: MapSet.new(),
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
      }
    }

    schedule_refresh_tick()
    schedule_geometry_tick()
    render(state)

    elapsed = Aiur.Boot.elapsed_ms()

    Logger.info(
      "aiur_agent_list phase=ready elapsed_ms=#{elapsed} agents=#{length(state.summaries)}"
    )

    # Emit through the same aiur_perf channel so the debug footer can
    # show "agent list ready: Xs" from the same data stream.
    Aiur.Perf.event(:agent_list_ready, wall_ms: elapsed)

    {:ok, state}
  end

  defp schedule_refresh_tick do
    Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
  end

  defp schedule_geometry_tick do
    Process.send_after(self(), :geometry_tick, @geometry_tick_ms)
  end

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
    if state.selection_focus == :agents do
      case Enum.at(state.summaries, state.selection_index) do
        %{identifier: identifier} = summary ->
          Logger.info("[user-action] open_conversation identifier=#{identifier} source=agent_list")
          Aiur.Perf.event(:user_pressed_enter, identifier: identifier, source: :agent_list)
          command = "#{state.command_template} #{identifier}"
          title = Map.get(summary, :title)
          pane_manager = state.pane_manager

          # PaneManager.open_conversation parks the call when no slot is
          # ready (cold pre-warm) and replies after the queue drains —
          # up to 60 s. The AgentList GenServer is the keyboard owner;
          # it must NOT block on this call or any keystroke pressed
          # during the wait is lost and the process times out + crashes.
          # Fire-and-forget in a Task instead.
          Task.start(fn ->
            PaneManager.open_conversation(pane_manager, identifier, command, title: title)
          end)

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  def handle_cast(:attach_selected, state) do
    if state.selection_focus == :agents do
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
          Task.start(fn ->
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
          end)

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  def handle_cast(:toggle_pause, state) do
    state = toggle_selected_agent_pause(state)
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

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info({:running_changed, summaries}, state) do
    summaries = visible_summaries(summaries)
    selection_focus = if state.summaries == [] and summaries != [], do: :agents, else: state.selection_focus
    new_state = clamp_selection(%{state | summaries: summaries, selection_focus: selection_focus})

    # Tell AttachPool which identifiers should have warm opencode-
    # attach panes ready. Seeding is idempotent — the pool ignores
    # already-known ids.
    active_ids =
      summaries
      |> Enum.filter(fn s -> Map.get(s, :status) == :running end)
      |> Enum.map(&Map.get(&1, :identifier))
      |> Enum.reject(&is_nil/1)

    _ = safely_seed_attach_pool(active_ids)
    render(new_state)
    {:noreply, new_state}
  end

  # The agent-list circle indicator no longer tracks "pane has ever
  # been opened" — it tracks "session is currently visible in some
  # slot", updated via `:slot_session_changed` below. Any other
  # `:status_changed` event is informational and not rendered.
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

  def handle_info({:slot_ready, _slot_index}, state), do: {:noreply, state}

  def handle_info({:poll_state_changed, payload}, state) do
    {:noreply, %{state | poll_state: payload}}
  end

  def handle_info({:alert, %{}}, state), do: {:noreply, state}

  def handle_info(:clear_max_agents_alert, state) do
    new_state = %{state | max_agents_alert?: false}
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

  def handle_info({:attach_warming, identifier, _slot_index}, state) do
    new_state = update_in(state.warming_identifiers, &MapSet.put(&1, identifier))
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:attach_warm, identifier, _pane_id, _slot_index}, state) do
    new_state =
      state
      |> Map.update!(:warm_identifiers, &MapSet.put(&1, identifier))
      |> Map.update!(:warming_identifiers, &MapSet.delete(&1, identifier))

    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:attach_consumed, identifier, _pane_id, _slot_index}, state) do
    # Identifier was opened — the warm pane is gone. Re-warming is
    # left to a future iteration (the slot is now :active and would
    # need to be re-cycled).
    new_state =
      state
      |> Map.update!(:warm_identifiers, &MapSet.delete(&1, identifier))
      |> Map.update!(:warming_identifiers, &MapSet.delete(&1, identifier))

    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:aiur_perf, event}, %{debug_mode?: true} = state) do
    new_summary = update_perf_summary(state.perf_summary, event)
    new_state = %{state | perf_summary: new_summary}

    if new_summary != state.perf_summary do
      render(new_state)
    end

    {:noreply, new_state}
  end

  def handle_info({:aiur_perf, _event}, state), do: {:noreply, state}

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

  def handle_info(_other, state), do: {:noreply, state}

  defp safely_seed_attach_pool([]), do: :ok

  defp safely_seed_attach_pool(identifiers) do
    Aiur.Opencode.AttachPool.seed(identifiers)
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
  # the max chip. Previously only :max_concurrent_agents_reached and
  # :below_active_count surfaced — every other reason (no_running_agent,
  # not_resumable, dispatch_failed, agent_paused) was swallowed silently,
  # which is what made the cap feel like it wasn't being applied.
  defp handle_resume_result(state, {:error, _reason}) do
    ring_bell(state)
    schedule_max_agents_alert_clear()
    %{state | max_agents_alert?: true}
  end

  defp handle_max_adjust_result(state, {:ok, _status}), do: state

  defp handle_max_adjust_result(state, {:error, :below_active_count}) do
    ring_bell(state)
    schedule_max_agents_alert_clear()
    %{state | max_agents_alert?: true}
  end

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

  defp toggle_selected_agent_pause(%{selection_focus: :agents} = state) do
    state.summaries
    |> Enum.at(state.selection_index)
    |> toggle_agent_pause(state)
  end

  defp toggle_selected_agent_pause(state), do: state

  defp toggle_agent_pause(%{identifier: identifier, status: :running} = summary, state) do
    if paused_summary?(summary) do
      Logger.info("[user-action] resume_agent identifier=#{identifier} source=agent_list")
      handle_resume_result(state, Orchestrator.resume_agent(state.orchestrator, identifier))
    else
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
      # Group by status emoji (matches what the renderer paints), then
      # by numeric identifier ASCENDING within each group. Previously
      # sorted identifiers as strings, so "10" came before "5" — the
      # user explicitly asked for natural numeric order within each
      # status-emoji bucket.
      emoji_bucket = emoji_sort_key(s)
      id_key = identifier_sort_key(Map.get(s, :identifier))
      {emoji_bucket, id_key}
    end)
  end

  # Map status emoji to a stable sort bucket. Lower = higher in the list.
  # Mirrors `Aiur.AgentList.Renderer.summary_emoji/1` so list order
  # matches what the user sees painted next to each row.
  defp emoji_sort_key(%{status: :queued}), do: 4

  defp emoji_sort_key(%{status: :running} = summary) do
    case Map.get(summary, :work_state) do
      # 🟢 actively working — most useful to see first
      :working -> 0
      # ⏸️ paused — still alive, less urgent than working
      :paused -> 1
      # 🔴 error — surface above queued but below healthy
      :error -> 2
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
      |> Map.put(:refresh_label, refresh_label_from_state(state))
      |> Map.put(:agent_kind, agent_kind())
      |> Map.put(:agent_count, active_agent_count(state.summaries))
      |> Map.put(:max_agents, max_agents_from_state(state))
      |> Map.put(:visible_sessions, state.visible_sessions)
      |> Map.put(:debug_mode?, Map.get(state, :debug_mode?, false))
      |> Map.put(:perf_summary, Map.get(state, :perf_summary, %{}))
      |> Map.put(:warm_identifiers, Map.get(state, :warm_identifiers, MapSet.new()))
      |> Map.put(:warming_identifiers, Map.get(state, :warming_identifiers, MapSet.new()))

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

  # Compute the countdown label from cached state — no GenServer.call.
  # The orchestrator broadcasts `:poll_state_changed` whenever its
  # mailbox-blocking poll cycle starts or finishes; in between, this
  # function just subtracts wall time from the cached due-at stamp.
  defp refresh_label_from_state(%{poll_state: %{checking?: true}}) do
    # In-progress collapses to "0s" — same calm reading the legacy
    # path produced via the orchestrator's `checking?` flag.
    "0s"
  end

  defp refresh_label_from_state(%{poll_state: %{next_poll_due_at_ms: due_at}})
       when is_integer(due_at) do
    # The orchestrator stamps `next_poll_due_at_ms` with
    # `System.monotonic_time(:millisecond)`, so we must read against the
    # same base. Using `System.system_time/1` would give garbage.
    ms = due_at - System.monotonic_time(:millisecond)
    seconds = div(max(ms, 0) + 999, 1000)
    "#{seconds}s"
  end

  defp refresh_label_from_state(_state), do: nil

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

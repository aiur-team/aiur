defmodule Aiur.AgentList.State do
  @moduledoc """
  Initial AgentList state construction.
  """

  alias Aiur.AgentList.RenderState
  alias Aiur.{Orchestrator, PaneManager}

  @type t :: %{
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

  @spec new(keyword()) :: map()
  def new(opts) do
    write_fun = Keyword.get(opts, :write_fun, &IO.write/1)
    pane_manager = Keyword.get(opts, :pane_manager, PaneManager)
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
    tmux = Keyword.get(opts, :tmux, Aiur.Tmux)
    command_template = Keyword.fetch!(opts, :command_template)
    {cols, rows} = RenderState.terminal_geometry()

    debug_mode? = Keyword.get(opts, :debug?, debug_env?())
    {prewarm_active?, prewarm_phase} = initial_prewarm_state()

    %{
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
      # Per-identifier presentation maps derived from the daemon-owned
      # TicketActivity projection. AgentList joins through trusted tracker
      # identity and never folds raw event bodies into these maps.
      latest_event_by_id: %{},
      # Per-identifier count of currently-open `attention.*` slugs,
      # driving the `❗` / `❗N` slot in the State column. Refreshed
      # from `Aiur.Events.SubscriptionStore.snapshot/1` on every
      # `running_changed` broadcast (agents come and go infrequently
      # enough that polling on summary updates beats per-event
      # incremental tracking).
      open_attentions_by_id: %{},
      progress_by_id: %{},
      phase_by_identifier: %{},
      activity_status_by_identifier: %{},
      ticket_activity_generation: -1,
      ticket_activity_by_identity: %{},
      ticket_activity_presented: %{},
      ticket_activity_snapshot_fun: Keyword.get(opts, :ticket_activity_snapshot_fun, &Aiur.TicketActivity.snapshots/0),
      ticket_activity_subscribe_fun: Keyword.get(opts, :ticket_activity_subscribe_fun, &Aiur.TicketActivity.subscribe/0),
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
  end

  defp debug_env? do
    case System.get_env("AIUR_DEBUG") do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["1", "true", "yes"]

      _ ->
        false
    end
  end

  defp warm_status_dark_mode_default do
    Application.get_env(:aiur, :warm_status_dark_mode?, true)
  end

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
end
